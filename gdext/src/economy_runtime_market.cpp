#include "economy_runtime.h"
#include "country_runtime.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <limits>

namespace pk {

namespace {
using Clock = std::chrono::steady_clock;

constexpr int32_t PRICE_NUMERIC_GUARD_MIN = 1;
constexpr int32_t PRICE_NUMERIC_GUARD_MAX = std::numeric_limits<int32_t>::max();

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}
} // namespace

int64_t NativeEconomyRuntime::variant_unit_price(int32_t market, int32_t variant_id,
                                                  int64_t &sat) const {
    if (market < 0 || market >= _market.market_count || variant_id < 0 ||
        variant_id >= static_cast<int32_t>(_variants.size())) return 1;
    const VariantChoice &variant = _variants[variant_id];
    int64_t unit_price = 0;
    for (int32_t c = 0; c < variant.component_count; ++c) {
        const NeedComponent &component = _components[variant.component_begin + c];
        unit_price = saturating_add(
            unit_price,
            mul_div_sat(effective_household_good_quantity(
                            market, component.good_id, component.qty_per_need, sat),
                        _market.price[_market.index(market, component.good_id)],
                        GOODS_SCALE, sat), sat);
    }
    return std::max<int64_t>(1, unit_price);
}

void NativeEconomyRuntime::build_demand_basis(
        int32_t market, const EnvironmentSample &sample,
        std::vector<int64_t> &variant_scores, std::vector<int64_t> &variant_prices,
        std::vector<int64_t> &need_score_sums, std::vector<int64_t> &need_composites,
        std::vector<int64_t> &need_environment, int64_t &sat) const {
    variant_scores.assign(_variants.size(), 0);
    variant_prices.assign(_variants.size(), 1);
    need_score_sums.assign(_needs.size(), 0);
    need_composites.assign(_needs.size(), 0);
    need_environment.assign(_needs.size(), Q16_ONE);
    const int32_t country = _epoch_active && market >= 0 &&
            market < static_cast<int32_t>(_epoch_cell_country.size())
        ? _epoch_cell_country[market] : -1;
    for (int32_t need_index = 0; need_index < static_cast<int32_t>(_needs.size()); ++need_index) {
        const Need &need = _needs[need_index];
        int64_t score_sum = 0;
        int64_t preference_sum = 0;
        need_environment[need_index] =
            sample_environment_curve(need.quantity_env_curve, sample);
        for (int32_t v = 0; v < need.variant_count; ++v) {
            const int32_t variant_id = need.variant_begin + v;
            const VariantChoice &variant = _variants[variant_id];
            const size_t availability_index =
                static_cast<size_t>(std::max(0, country)) * _variants.size() +
                static_cast<size_t>(variant_id);
            const bool technology_available = country >= 0 &&
                country < _epoch_country_count &&
                availability_index < _epoch_country_variant_available.size()
                ? _epoch_country_variant_available[availability_index] != 0
                : [&]() {
                    for (int32_t c = 0; c < variant.component_count; ++c) {
                        const NeedComponent &component =
                            _components[variant.component_begin + c];
                        if (!good_available(
                                market, component.good_id, true)) return false;
                    }
                    return true;
                }();
            if (!technology_available) continue;
            const int64_t unit_price = variant_unit_price(market, variant_id, sat);
            const int64_t price_ratio = mul_div_sat(
                variant.reference_unit_price, Q16_ONE, unit_price, sat);
            int64_t score = mul_div_sat(
                variant.preference_q16,
                pow_q16(std::max<int64_t>(1, price_ratio),
                        variant.price_elasticity_q16, sat), Q16_ONE, sat);
            score = mul_div_sat(score,
                sample_environment_curve(variant.preference_env_curve, sample), Q16_ONE, sat);
            score = std::max<int64_t>(0, score);
            variant_prices[variant_id] = unit_price;
            variant_scores[variant_id] = score;
            score_sum = saturating_add(score_sum, score, sat);
            preference_sum = saturating_add(
                preference_sum, std::max<int32_t>(1, variant.preference_q16), sat);
        }
        need_score_sums[need_index] = score_sum;
        const int64_t raw_composite = score_sum > 0
            ? mul_div_sat(score_sum, Q16_ONE, std::max<int64_t>(1, preference_sum), sat)
            : 0;
        need_composites[need_index] = raw_composite > 0
            ? std::clamp<int64_t>(pow_q16(
                std::max<int64_t>(1, raw_composite),
                need.price_quantity_elasticity_q16, sat),
                need.price_quantity_floor_q16, Q16_ONE * 2)
            : 0;
    }
}

int64_t NativeEconomyRuntime::desired_need_units(
        int32_t slot, int32_t need_index, int32_t dt_days,
        int64_t environment_factor_q16, int64_t composite_factor_q16,
        int64_t &sat) const {
    const int64_t funds = slot >= 0 && slot < static_cast<int32_t>(_population.funds.size())
        ? _population.funds[slot] : 0;
    return desired_need_units_for_funds(
        slot, need_index, dt_days, environment_factor_q16,
        composite_factor_q16, funds, sat);
}

int64_t NativeEconomyRuntime::desired_need_units_for_funds(
        int32_t slot, int32_t need_index, int32_t dt_days,
        int64_t environment_factor_q16, int64_t composite_factor_q16,
        int64_t funds, int64_t &sat) const {
    if (slot < 0 || slot >= static_cast<int32_t>(_population.active.size()) ||
        _population.active[slot] == 0 || need_index < 0 ||
        need_index >= static_cast<int32_t>(_needs.size())) return 0;
    const int64_t population = std::max<int64_t>(0, _population.population[slot]);
    return desired_need_units_for_actor(
        slot, need_index, dt_days, environment_factor_q16,
        composite_factor_q16, population, funds, sat);
}

bool NativeEconomyRuntime::drain_committed_gameplay_facts(
        std::vector<CommittedGameplayFact> &out) {
    if (_committed_gameplay_facts.empty()) return false;
    out.swap(_committed_gameplay_facts);
    _committed_gameplay_facts.clear();
    return true;
}

int64_t NativeEconomyRuntime::desired_need_units_for_actor(
        int32_t slot, int32_t need_index, int32_t dt_days,
        int64_t environment_factor_q16, int64_t composite_factor_q16,
        int64_t actor_population, int64_t actor_funds, int64_t &sat) const {
    if (slot < 0 || slot >= static_cast<int32_t>(_population.active.size()) ||
        _population.active[slot] == 0 || need_index < 0 ||
        need_index >= static_cast<int32_t>(_needs.size())) return 0;
    const uint32_t signature_id = _population.signature_id[slot];
    if (signature_id >= _signatures.size()) return 0;
    const Signature &signature = _signatures[signature_id];
    const Need &need = _needs[need_index];
    const int64_t population = std::max<int64_t>(0, actor_population);
    if (population <= 0) return 0;
    const int64_t wealth_pc = std::max<int64_t>(0, actor_funds) / population;
    const int64_t wealth_ratio_q16 = mul_div_sat(
        wealth_pc, Q16_ONE, _wealth_reference_per_capita, sat);
    int64_t wealth_factor = pow_q16(std::max<int64_t>(1, wealth_ratio_q16),
                                    need.wealth_elasticity_q16, sat);
    wealth_factor = std::clamp<int64_t>(wealth_factor,
                                        need.wealth_min_q16, need.wealth_max_q16);
    int64_t desired = saturating_mul(population, need.base_qty_per_person, sat);
    desired = saturating_mul(desired, std::max(1, dt_days), sat);
    desired = mul_div_sat(desired, wealth_factor, Q16_ONE, sat);
    desired = mul_div_sat(desired, environment_factor_q16, Q16_ONE, sat);
    const int64_t ethnicity_factor = _ethnicity_need_factor_q16[
        static_cast<size_t>(signature.ethnicity_id) * _need_ids.size() + need.stable_id];
    desired = mul_div_sat(desired, ethnicity_factor, Q16_ONE, sat);
    desired = mul_div_sat(desired, composite_factor_q16, Q16_ONE, sat);
    // Family consumption preference is a cohort-level demand overlay. It is
    // intentionally applied before market ordering so the cohort still emits
    // one conserved order stream and anonymous population remains neutral.
    desired = mul_div_sat(desired,
        family_consumption_factor_q16(slot, need.stable_id), Q16_ONE, sat);
    return std::max<int64_t>(0, desired);
}

void NativeEconomyRuntime::compute_cohort_demand_preview(
        int32_t slot, int32_t market, const EnvironmentSample &sample,
        const std::vector<int32_t> *price_override, int64_t funds_override,
        std::vector<int64_t> &good_per_capita_daily, int64_t &sat) const {
    good_per_capita_daily.assign(_market.good_count, 0);
    if (slot < 0 || slot >= static_cast<int32_t>(_population.active.size()) ||
        _population.active[slot] == 0 || market < 0 || market >= _market.market_count)
        return;
    const uint32_t signature_id = _population.signature_id[slot];
    if (signature_id >= _signatures.size()) return;
    std::vector<int64_t> variant_scores(_variants.size(), 0);
    std::vector<int64_t> need_score_sums(_needs.size(), 0);
    std::vector<int64_t> need_composites(_needs.size(), 0);
    std::vector<int64_t> need_environment(_needs.size(), Q16_ONE);
    const int32_t country = _epoch_active && market >= 0 &&
            market < static_cast<int32_t>(_epoch_cell_country.size())
        ? _epoch_cell_country[market] : -1;
    for (int32_t need_index = 0; need_index < static_cast<int32_t>(_needs.size()); ++need_index) {
        const Need &need = _needs[need_index];
        int64_t score_sum = 0;
        int64_t preference_sum = 0;
        need_environment[need_index] = sample_environment_curve(need.quantity_env_curve, sample);
        for (int32_t v = 0; v < need.variant_count; ++v) {
            const int32_t variant_id = need.variant_begin + v;
            const VariantChoice &variant = _variants[variant_id];
            const size_t availability_index =
                static_cast<size_t>(std::max(0, country)) * _variants.size() +
                static_cast<size_t>(variant_id);
            bool available = country >= 0 && country < _epoch_country_count &&
                availability_index < _epoch_country_variant_available.size()
                ? _epoch_country_variant_available[availability_index] != 0
                : true;
            int64_t unit_price = 0;
            for (int32_t c = 0; c < variant.component_count; ++c) {
                const NeedComponent &component = _components[variant.component_begin + c];
                if (country < 0 ||
                    availability_index >=
                        _epoch_country_variant_available.size()) {
                    available &=
                        good_available(market, component.good_id, true);
                }
                const int32_t price = price_override != nullptr &&
                        component.good_id < static_cast<int32_t>(price_override->size())
                    ? (*price_override)[component.good_id]
                    : _market.price[_market.index(market, component.good_id)];
                unit_price = saturating_add(unit_price, mul_div_sat(
                    effective_household_good_quantity(
                        market, component.good_id, component.qty_per_need, sat),
                    price, GOODS_SCALE, sat), sat);
            }
            if (!available) continue;
            unit_price = std::max<int64_t>(1, unit_price);
            const int64_t price_ratio = mul_div_sat(
                variant.reference_unit_price, Q16_ONE, unit_price, sat);
            int64_t score = mul_div_sat(
                variant.preference_q16,
                pow_q16(std::max<int64_t>(1, price_ratio),
                        variant.price_elasticity_q16, sat), Q16_ONE, sat);
            score = mul_div_sat(score,
                sample_environment_curve(variant.preference_env_curve, sample), Q16_ONE, sat);
            score = std::max<int64_t>(0, score);
            variant_scores[variant_id] = score;
            score_sum = saturating_add(score_sum, score, sat);
            preference_sum = saturating_add(
                preference_sum, std::max<int32_t>(1, variant.preference_q16), sat);
        }
        need_score_sums[need_index] = score_sum;
        const int64_t raw_composite = score_sum > 0
            ? mul_div_sat(score_sum, Q16_ONE, std::max<int64_t>(1, preference_sum), sat) : 0;
        need_composites[need_index] = raw_composite > 0
            ? std::clamp<int64_t>(pow_q16(std::max<int64_t>(1, raw_composite),
                need.price_quantity_elasticity_q16, sat),
                need.price_quantity_floor_q16, Q16_ONE * 2) : 0;
    }
    const Plan &plan = _plans[_signatures[signature_id].plan_id];
    const int64_t population = std::max<int64_t>(1, _population.population[slot]);
    std::vector<int64_t> totals(_market.good_count, 0);
    for (int32_t n = 0; n < plan.need_count; ++n) {
        const int32_t need_index = plan.need_begin + n;
        const Need &need = _needs[need_index];
        const int64_t base_score_sum = need_score_sums[need_index];
        std::array<int64_t, MAX_VARIANTS_PER_NEED> cohort_variant_scores{};
        int64_t score_sum = 0;
        for (int32_t v = 0; v < need.variant_count; ++v) {
            const int32_t variant_id = need.variant_begin + v;
            cohort_variant_scores[v] = std::max<int64_t>(0, mul_div_sat(
                variant_scores[variant_id],
                family_variant_preference_factor_q16(slot, variant_id, sat),
                Q16_ONE, sat));
            score_sum = saturating_add(
                score_sum, cohort_variant_scores[v], sat);
        }
        if (score_sum <= 0) continue;
        int64_t desired = desired_need_units_for_funds(
            slot, need_index, 1, need_environment[need_index],
            need_composites[need_index], funds_override, sat);
        if (base_score_sum > 0) {
            desired = mul_div_sat(
                desired, score_sum, base_score_sum, sat);
        }
        int64_t prefix = 0;
        int64_t allocated = 0;
        for (int32_t v = 0; v < need.variant_count; ++v) {
            const int32_t variant_id = need.variant_begin + v;
            prefix = saturating_add(prefix, cohort_variant_scores[v], sat);
            const int64_t next = mul_div_sat(desired, prefix, score_sum, sat);
            const int64_t units = std::max<int64_t>(0, next - allocated);
            allocated = next;
            const VariantChoice &variant = _variants[variant_id];
            for (int32_t c = 0; c < variant.component_count; ++c) {
                const NeedComponent &component = _components[variant.component_begin + c];
                totals[component.good_id] = saturating_add(totals[component.good_id],
                    mul_div_sat(units, effective_household_good_quantity(
                        market, component.good_id, component.qty_per_need, sat),
                        GOODS_SCALE, sat), sat);
            }
        }
    }
    for (int32_t good = 0; good < _market.good_count; ++good)
        good_per_capita_daily[good] = totals[good] / population;
}

int64_t NativeEconomyRuntime::survival_required_units(
        int32_t slot, int32_t stable_need_id, int32_t dt_days,
        const EnvironmentSample &sample, int64_t &sat) const {
    if (slot < 0 || slot >= static_cast<int32_t>(_population.active.size()) ||
        _population.active[slot] == 0 || stable_need_id < 0 ||
        stable_need_id >= static_cast<int32_t>(_survival_required_need_indices.size())) return 0;
    const int32_t need_index = _survival_required_need_indices[stable_need_id];
    if (need_index < 0 || need_index >= static_cast<int32_t>(_needs.size())) return 0;
    const uint32_t signature_id = _population.signature_id[slot];
    if (signature_id >= _signatures.size()) return 0;
    const Signature &signature = _signatures[signature_id];
    const Need &need = _needs[need_index];
    const int64_t population = std::max<int64_t>(0, _population.population[slot]);
    if (population <= 0) return 0;
    int64_t required = saturating_mul(population, need.base_qty_per_person, sat);
    required = saturating_mul(required, std::max(1, dt_days), sat);
    required = mul_div_sat(required,
        sample_environment_curve(need.quantity_env_curve, sample), Q16_ONE, sat);
    const int64_t ethnicity_factor = _ethnicity_need_factor_q16[
        static_cast<size_t>(signature.ethnicity_id) * _need_ids.size() + stable_need_id];
    required = mul_div_sat(required, ethnicity_factor, Q16_ONE, sat);
    return std::max<int64_t>(0, required);
}

// ─── Fixed point / formula registry ────────────────────────────────────

// Fixed-point and pure formula implementations live in
// economy_runtime_math.cpp. This file keeps orchestration and stateful stages.

bool NativeEconomyRuntime::process_market_cell(int32_t market, MarketResult &result,
                                              std::string &error) {
    MarketResult *previous_market_sink = _market_result_sink;
    _market_result_sink = &result;
    struct MarketSinkRestore {
        MarketResult *&sink;
        MarketResult *previous = nullptr;
        ~MarketSinkRestore() { sink = previous; }
    } market_sink_restore{_market_result_sink, previous_market_sink};
    struct NeedState {
        int32_t local_cohort = -1;
        int32_t need_index = -1;
        int64_t desired_units = 0;
        int64_t filled_units = 0;
        int64_t spent_money = 0;
    };
    struct ComponentRef {
        int32_t order = -1;
        int64_t required_qty = 0;
        int64_t qty_per_need = 0;
    };
    thread_local std::vector<int32_t> slots;
    thread_local std::vector<NeedState> need_states;
    thread_local std::vector<BundleOrder> primary_orders;
    thread_local std::vector<BundleOrder> fallback_orders;
    thread_local std::vector<int64_t> cohort_spend;
    thread_local std::vector<int64_t> cohort_base_spend;
    thread_local std::vector<int64_t> cohort_consumption_tax;
    thread_local std::vector<int64_t> cohort_consumption_subsidy;
    thread_local std::vector<int64_t> cohort_desired;
    thread_local std::vector<int64_t> cohort_filled;
    thread_local std::vector<int64_t> cohort_food_required;
    thread_local std::vector<int64_t> cohort_food_filled;
    thread_local std::vector<int64_t> cohort_subsistence_food_filled;
    thread_local std::vector<int64_t> cohort_best_food_q16;
    thread_local std::vector<int64_t> cohort_clothing_required;
    thread_local std::vector<int64_t> cohort_clothing_filled;
    thread_local std::vector<int64_t> cohort_working_capital_reserve;
    thread_local std::vector<int64_t> production_input_floor;
    thread_local std::vector<int64_t> good_demand;
    thread_local std::vector<int64_t> good_sales;
    thread_local std::vector<int64_t> pass_sales;
    thread_local std::vector<int64_t> pass_demand;
    thread_local std::vector<int64_t> opening_stock;
    thread_local std::vector<int64_t> trace_funds_before;
    thread_local std::vector<int64_t> trace_income_before;
    thread_local std::vector<int64_t> trace_expense_before;
    thread_local std::vector<int64_t> trace_income_ema_before;
    thread_local std::vector<uint16_t> trace_satisfaction_before;
    thread_local std::vector<uint16_t> trace_worst_need_before;
    thread_local std::vector<int32_t> trace_price_before;
    thread_local std::vector<int64_t> trace_demand_ema_before;
    thread_local std::vector<uint16_t> trace_shortage_before;
    thread_local std::vector<int32_t> good_counts;
    thread_local std::vector<int32_t> good_offsets;
    thread_local std::vector<int32_t> good_cursor;
    thread_local std::vector<ComponentRef> component_refs;
    thread_local std::vector<int64_t> variant_score_cache;
    thread_local std::vector<int64_t> variant_price_cache;
    thread_local std::vector<int64_t> need_score_sum_cache;
    thread_local std::vector<int64_t> need_composite_cache;
    thread_local std::vector<int64_t> need_environment_cache;
    thread_local std::vector<int64_t> cohort_worst_q16;
    thread_local std::vector<uint16_t> cohort_worst_need;
    // Need-tier reduction, strided by SAT_TIER_COUNT per local cohort. A tier the
    // cohort's plan never mentions keeps a zero weight and is dropped from the
    // composite denominator, so a plan without luxuries is not penalized.
    thread_local std::vector<int64_t> cohort_tier_weighted_q16;
    thread_local std::vector<int64_t> cohort_tier_weight_q16;
    thread_local std::vector<int64_t> expected_births_q32_by_ethnicity;
    thread_local std::vector<int64_t> cohort_rescale_sat_q16;
    thread_local std::array<int64_t, 3> food_family_filled{};
    thread_local std::array<int64_t, 3> food_family_desired{};
    thread_local std::vector<int32_t> local_by_slot;
    thread_local std::vector<uint32_t> local_by_slot_stamp;
    thread_local uint32_t local_lookup_generation = 0;
    int64_t &sat = result.saturation_count;
    bool population_changed = false;
    if (market < 0 || market >= _market.market_count) {
        error = "household_market_out_of_range";
        return false;
    }
    if (_market_cell_offsets.size() != static_cast<size_t>(_market.market_count + 1)) {
        error = "market_cell_range_missing";
        return false;
    }
    const size_t expected_birth_residuals =
        static_cast<size_t>(_cell_count) * _ethnicity_ids.size();
    if (_birth_residual_q32.size() != expected_birth_residuals) {
        error = "birth_residual_shape_mismatch";
        return false;
    }
    slots.clear();
    for (int32_t k = _market_cell_offsets[market]; k < _market_cell_offsets[market + 1]; ++k) {
        const int32_t market_cell = _market_cells[k];
        _population.for_each_in_cell(market_cell, [&](int32_t slot) { slots.push_back(slot); });
    }
    const int32_t cohort_count = static_cast<int32_t>(slots.size());
    int64_t opening_market_population = 0;
    for (const int32_t slot : slots) {
        opening_market_population = saturating_add(
            opening_market_population, std::max<int64_t>(0, _population.population[slot]),
            sat);
    }
    thread_local std::vector<int32_t> living_merchants;
    collect_living_merchant_slots(market, living_merchants);
    if (opening_market_population > 0 && living_merchants.empty()) {
        error = "market_revenue_has_no_merchant_owner";
        return false;
    }
    if (local_by_slot.size() < _population.active.size()) {
        local_by_slot.resize(_population.active.size(), -1);
        local_by_slot_stamp.resize(_population.active.size(), 0);
    }
    ++local_lookup_generation;
    if (local_lookup_generation == 0) {
        std::fill(local_by_slot_stamp.begin(), local_by_slot_stamp.end(), 0);
        local_lookup_generation = 1;
    }
    for (int32_t local = 0; local < cohort_count; ++local) {
        const int32_t slot = slots[local];
        local_by_slot[slot] = local;
        local_by_slot_stamp[slot] = local_lookup_generation;
    }
    const bool trace_detail = trace_detail_for_cell(market);
    result.cashflows.clear();
    result.welfare_entries.clear();
    need_states.clear();
    primary_orders.clear();
    fallback_orders.clear();
    cohort_spend.assign(cohort_count, 0);
    cohort_base_spend.assign(cohort_count, 0);
    cohort_consumption_tax.assign(cohort_count, 0);
    cohort_consumption_subsidy.assign(cohort_count, 0);
    cohort_desired.assign(cohort_count, 0);
    cohort_filled.assign(cohort_count, 0);
    cohort_food_required.assign(cohort_count, 0);
    cohort_food_filled.assign(cohort_count, 0);
    cohort_subsistence_food_filled.assign(cohort_count, 0);
    cohort_best_food_q16.assign(cohort_count, 0);
    cohort_clothing_required.assign(cohort_count, 0);
    cohort_clothing_filled.assign(cohort_count, 0);
    cohort_tier_weighted_q16.assign(
        static_cast<size_t>(cohort_count) * SAT_TIER_COUNT, 0);
    cohort_tier_weight_q16.assign(
        static_cast<size_t>(cohort_count) * SAT_TIER_COUNT, 0);
    expected_births_q32_by_ethnicity.assign(_ethnicity_ids.size(), 0);
    cohort_rescale_sat_q16.assign(cohort_count, Q16_ONE);
    food_family_filled.fill(0);
    food_family_desired.fill(0);
    result.retained_consumed_by_good.assign(_market.good_count, 0);
    cohort_working_capital_reserve.assign(cohort_count, 0);
    production_input_floor.assign(_market.good_count, 0);
    good_demand.assign(_market.good_count, 0);
    good_sales.assign(_market.good_count, 0);
    opening_stock.resize(_market.good_count);
    for (int32_t good = 0; good < _market.good_count; ++good) {
        opening_stock[good] = _market.stock[_market.index(market, good)];
    }
    for (int32_t k = _market_cell_offsets[market];
         k < _market_cell_offsets[market + 1]; ++k) {
        const int32_t cell = _market_cells[k];
        if (_market_signals.cell_offsets.size() != static_cast<size_t>(_cell_count + 1))
            continue;
        for (int32_t signal = _market_signals.cell_offsets[cell];
             signal < _market_signals.cell_offsets[cell + 1]; ++signal) {
            if (signal >= static_cast<int32_t>(_production_input_reserve.size())) continue;
            const int32_t good = _market_signals.good_ids[signal];
            production_input_floor[good] = saturating_add(
                production_input_floor[good], _production_input_reserve[signal], sat);
        }
    }
    if (trace_detail) {
        trace_funds_before.resize(cohort_count);
        trace_income_before.resize(cohort_count);
        trace_expense_before.resize(cohort_count);
        trace_income_ema_before.resize(cohort_count);
        trace_satisfaction_before.resize(cohort_count);
        trace_worst_need_before.resize(cohort_count);
        for (int32_t local = 0; local < cohort_count; ++local) {
            const int32_t slot = slots[local];
            trace_funds_before[local] = _population.funds[slot];
            trace_income_before[local] = _population.epoch_income[slot];
            trace_expense_before[local] = _population.epoch_expense[slot];
            trace_income_ema_before[local] = _population.income_ema[slot];
            trace_satisfaction_before[local] = _population.needs_satisfaction[slot];
            trace_worst_need_before[local] = _population.worst_need_id[slot];
        }
        trace_price_before.resize(_market.good_count);
        trace_demand_ema_before.resize(_market.good_count);
        trace_shortage_before.resize(_market.good_count);
        for (int32_t good = 0; good < _market.good_count; ++good) {
            const int64_t idx = _market.index(market, good);
            trace_price_before[good] = _market.price[idx];
            trace_demand_ema_before[good] = _market.demand_ema[idx];
            trace_shortage_before[good] = _market.last_shortage_q16[idx];
        }
    }
    for (int32_t slot : slots) touch_accounting_slot(slot);

    // Household clearing must not consume the physical-input float needed to
    // start the next production period. Output is sold after inputs are bought,
    // so an owner cohort with no protected working capital cannot self-recover.
    for (int32_t k = _market_cell_offsets[market]; k < _market_cell_offsets[market + 1]; ++k) {
        const int32_t cell = _market_cells[k];
        if (_building_cell_offsets.size() != static_cast<size_t>(_cell_count + 1)) continue;
        for (int32_t g = _building_cell_offsets[cell];
             g < _building_cell_offsets[cell + 1]; ++g) {
            const BuildingGroup &group = _buildings[g];
            if (group.count <= 0 || group.operating_state == 1 ||
                !building_available(cell, group.type_id, true)) continue;
            const BuildingType &type = _building_types[group.type_id];
            if (type.input_count <= 0 || group.sample_unit_input_cost <= 0) continue;
            const int32_t owner_slot = find_cohort_slot(cell, group.owner_signature_id);
            if (owner_slot < 0 ||
                owner_slot >= static_cast<int32_t>(local_by_slot_stamp.size()) ||
                local_by_slot_stamp[owner_slot] != local_lookup_generation) continue;
            const int32_t local = local_by_slot[owner_slot];
            const int64_t owner_demand = saturating_mul(
                group.count, type.owner_slots_per_building, sat);
            const int64_t owner_scale_q16 = owner_demand > 0
                ? std::min<int64_t>(Q16_ONE, mul_div_sat(
                    group.filled_owner, Q16_ONE, owner_demand, sat)) : 0;
            const int64_t operation_scale_q16 = std::min<int64_t>(
                owner_scale_q16, std::clamp<int64_t>(
                    group.planned_utilization_q16, 0, Q16_ONE));
            const int64_t full_period_cost = saturating_mul(
                saturating_mul(group.sample_unit_input_cost, group.count, sat),
                std::max(1, _epoch_days), sat);
            const int64_t reserve = mul_div_sat(
                full_period_cost, operation_scale_q16, Q16_ONE, sat);
            cohort_working_capital_reserve[local] = saturating_add(
                cohort_working_capital_reserve[local], reserve, sat);
            result.owner_working_capital_reserved = saturating_add(
                result.owner_working_capital_reserved, reserve, sat);
        }
    }

    const auto formula_start = Clock::now();
    // Price and environment are frozen for the whole market tick. Compile the
    // variant side once per market instead of repeating it for every cohort.
    const EnvironmentSample market_environment = environment_sample_for_cell(market);
    build_demand_basis_cached(market, market, market_environment,
                       variant_score_cache, variant_price_cache,
                       need_score_sum_cache, need_composite_cache,
                       need_environment_cache, sat);
    compute_cell_living_costs_from_basis(
        market, variant_score_cache, variant_price_cache,
        need_score_sum_cache, need_environment_cache, sat);
    // Market-invariant anytime frontier. The exact best-scoring variant is
    // always retained, then lower-ranked variants are added until the omitted
    // preference mass is within the configured certificate. Survival families
    // remain exact. PROBE builds the same frontier but does not apply it.
    std::vector<uint8_t> &approximation_variant_active =
        result.approximation_variant_active;
    bool approximation_policy_enabled =
        _accuracy_preset != 0 && _approximation_runtime_mode != 0 &&
        _approximation_cooldown_epochs_left == 0;
    if (approximation_policy_enabled &&
        _approximation_runtime_mode == 1) {
        uint64_t market_probe_hash = 1469598103934665603ULL;
        market_probe_hash = trace_hash_mix(
            market_probe_hash, static_cast<uint64_t>(_seed));
        market_probe_hash = trace_hash_mix(
            market_probe_hash, static_cast<uint64_t>(_current_day));
        market_probe_hash = trace_hash_mix(
            market_probe_hash, static_cast<uint32_t>(market));
        approximation_policy_enabled =
            static_cast<int32_t>(market_probe_hash & 0xffffULL) <
                _accuracy_exact_probe_rate_q16;
    }
    const bool approximation_apply =
        approximation_policy_enabled && _approximation_runtime_mode == 2;
    bool approximation_market_probe_failed = false;
    if (approximation_policy_enabled) {
        if (approximation_variant_active.size() != _variants.size()) {
            error = "approximation_worker_scratch_size_mismatch";
            return false;
        }
        std::fill(approximation_variant_active.begin(),
                  approximation_variant_active.end(), uint8_t{1});
        for (const Need &need : _needs) {
            const bool survival_need =
                (need.stable_id >= 0 &&
                 need.stable_id < static_cast<int32_t>(
                     _survival_food_need_mask.size()) &&
                 _survival_food_need_mask[need.stable_id] != 0) ||
                need.stable_id == _survival_clothing_need_stable_id;
            if (survival_need ||
                need.variant_count <= _accuracy_candidate_top_k) continue;
            uint64_t probe_hash = 1469598103934665603ULL;
            probe_hash = trace_hash_mix(
                probe_hash, static_cast<uint64_t>(_seed));
            probe_hash = trace_hash_mix(
                probe_hash, static_cast<uint64_t>(_current_day));
            probe_hash = trace_hash_mix(
                probe_hash, static_cast<uint32_t>(market));
            probe_hash = trace_hash_mix(
                probe_hash, static_cast<uint32_t>(need.stable_id));
            const bool exact_probe = _approximation_runtime_mode == 1 ||
                static_cast<int32_t>(probe_hash & 0xffffULL) <
                    _accuracy_exact_probe_rate_q16;
            if (exact_probe) ++result.approximation_exact_probes;
            ++result.approximation_decisions;
            result.approximation_frontier_candidates += need.variant_count;
            std::array<int32_t, MAX_VARIANTS_PER_NEED>
                approximation_variant_order{};
            const int32_t variant_count = std::min<int32_t>(
                need.variant_count, MAX_VARIANTS_PER_NEED);
            // Catalog ABI caps a need at eight variants. Stable insertion sort
            // avoids a heap-backed general sort in the market hot loop.
            for (int32_t candidate = 0; candidate < variant_count; ++candidate) {
                int32_t insert_at = candidate;
                const int64_t candidate_score =
                    variant_score_cache[need.variant_begin + candidate];
                while (insert_at > 0) {
                    const int32_t previous =
                        approximation_variant_order[insert_at - 1];
                    const int64_t previous_score =
                        variant_score_cache[need.variant_begin + previous];
                    if (previous_score >= candidate_score) break;
                    approximation_variant_order[insert_at] = previous;
                    --insert_at;
                }
                approximation_variant_order[insert_at] = candidate;
            }
            int64_t selected_score = 0;
            const int32_t initial_count = std::min(
                variant_count, _accuracy_candidate_top_k);
            for (int32_t rank = 0; rank < variant_count; ++rank) {
                approximation_variant_active[
                    need.variant_begin + approximation_variant_order[rank]] = 0;
            }
            for (int32_t rank = 0; rank < initial_count; ++rank) {
                const int32_t variant_id =
                    need.variant_begin + approximation_variant_order[rank];
                approximation_variant_active[variant_id] = 1;
                selected_score = saturating_add(
                    selected_score, std::max<int64_t>(
                        0, variant_score_cache[variant_id]), sat);
            }
            // Temperature widens the feasible near-best region; it does not
            // introduce RNG into authoritative choice or remove the optimum.
            const int64_t best_score = std::max<int64_t>(0,
                variant_score_cache[need.variant_begin +
                    approximation_variant_order[0]]);
            int32_t selected_count = initial_count;
            while (selected_count < variant_count) {
                const int32_t variant_id = need.variant_begin +
                    approximation_variant_order[selected_count];
                const int64_t score = std::max<int64_t>(
                    0, variant_score_cache[variant_id]);
                if (mul_div_sat(best_score,
                        Q16_ONE - _accuracy_choice_temperature_q16,
                        Q16_ONE, sat) > score) break;
                approximation_variant_active[variant_id] = 1;
                selected_score = saturating_add(
                    selected_score, score, sat);
                ++selected_count;
            }
            const int64_t total_score = std::max<int64_t>(
                0, need_score_sum_cache[&need - _needs.data()]);
            const int64_t allowed_omitted = mul_div_sat(
                total_score, _accuracy_household_tail_share_q16,
                Q16_ONE, sat);
            while (selected_count < variant_count &&
                   total_score - selected_score > allowed_omitted) {
                const int32_t variant_id = need.variant_begin +
                    approximation_variant_order[selected_count++];
                approximation_variant_active[variant_id] = 1;
                selected_score = saturating_add(
                    selected_score, std::max<int64_t>(
                        0, variant_score_cache[variant_id]), sat);
            }
            const bool certificate_valid =
                selected_count > 0 && selected_score > 0 &&
                total_score - selected_score <= allowed_omitted;
            if (!certificate_valid) {
                ++result.approximation_certificate_failures;
                ++result.approximation_exact_fallbacks;
                for (int32_t v = 0; v < variant_count; ++v)
                    approximation_variant_active[need.variant_begin + v] = 1;
                selected_count = variant_count;
                selected_score = total_score;
            }
            if (total_score > 0) {
                result.approximation_max_certified_regret_q16 = std::max(
                    result.approximation_max_certified_regret_q16,
                    mul_div_sat(std::max<int64_t>(
                        0, total_score - selected_score),
                        Q16_ONE, total_score, sat));
            }
            result.approximation_frontier_pruned +=
                variant_count - selected_count;

            if (exact_probe && certificate_valid &&
                selected_count < variant_count) {
                int64_t exact_price = 0;
                int64_t approximate_price = 0;
                for (int32_t rank = 0; rank < variant_count; ++rank) {
                    const int32_t variant_id = need.variant_begin +
                        approximation_variant_order[rank];
                    const int64_t score = std::max<int64_t>(
                        0, variant_score_cache[variant_id]);
                    const int64_t price = std::max<int64_t>(
                        0, variant_price_cache[variant_id]);
                    exact_price = saturating_add(exact_price, mul_div_sat(
                        price, score, std::max<int64_t>(1, total_score), sat),
                        sat);
                    if (rank < selected_count) {
                        approximate_price = saturating_add(
                            approximate_price, mul_div_sat(
                                price, score,
                                std::max<int64_t>(1, selected_score), sat),
                            sat);
                    }
                }
                const auto relative_error_q16 =
                    [&](int64_t actual, int64_t expected) -> int64_t {
                        const int64_t delta = actual >= expected
                            ? actual - expected : expected - actual;
                        return mul_div_sat(delta, Q16_ONE,
                            std::max<int64_t>(1, expected), sat);
                    };
                const int64_t spend_error_q16 =
                    relative_error_q16(approximate_price, exact_price);
                // With a frozen cohort budget, expected demand is inverse to
                // bundle price. Comparing the reciprocal cancels the budget.
                const int64_t demand_error_q16 = relative_error_q16(
                    exact_price, approximate_price);
                result.approximation_probe_max_spend_error_q16 = std::max(
                    result.approximation_probe_max_spend_error_q16,
                    spend_error_q16);
                result.approximation_probe_max_demand_error_q16 = std::max(
                    result.approximation_probe_max_demand_error_q16,
                    demand_error_q16);
                if (spend_error_q16 > _accuracy_max_regret_q16 ||
                    demand_error_q16 > _accuracy_max_regret_q16) {
                    ++result.approximation_probe_violations;
                    ++result.approximation_exact_fallbacks;
                    approximation_market_probe_failed = true;
                }
            }
        }
        if (approximation_market_probe_failed)
            std::fill(approximation_variant_active.begin(),
                      approximation_variant_active.end(), uint8_t{1});
    }
    const auto cohort_cell = [&](int32_t slot) {
        const int32_t page = slot / COHORT_PAGE_SIZE;
        return page >= 0 && page < static_cast<int32_t>(_population.page_cell.size())
            ? _population.page_cell[page] : -1;
    };
    const auto component_quantity = [&](int32_t slot,
            const NeedComponent &component) {
        return effective_household_good_quantity(
            cohort_cell(slot), component.good_id, component.qty_per_need, sat);
    };
    const bool consumption_tax_active =
        (_epoch_active_tax_mask & static_cast<uint8_t>(
            1U << NativeCountryRuntime::TAX_CONSUMPTION)) != 0;
    bool family_purchase_discount_active = false;
    for (int32_t local = 0; local < cohort_count; ++local) {
        if (family_purchase_pay_factor_q16(slots[local]) < Q16_ONE) {
            family_purchase_discount_active = true;
            break;
        }
    }
    const bool subsidy_settlement =
        consumption_tax_active || family_purchase_discount_active;
    const bool income_tax_active =
        (_epoch_active_tax_mask & static_cast<uint8_t>(
            1U << NativeCountryRuntime::TAX_INCOME)) != 0;
    const auto household_quote = [&](int32_t slot, int32_t variant_id,
                                     int64_t base_price) {
        if (!consumption_tax_active) return base_price;
        int64_t quoted = base_price;
        const int32_t cell = cohort_cell(slot);
        const VariantChoice &variant = _variants[variant_id];
        for (int32_t c = 0; c < variant.component_count; ++c) {
            const NeedComponent &component =
                _components[variant.component_begin + c];
            const int8_t rate = frozen_tax_rate(
                cell, NativeCountryRuntime::TAX_CONSUMPTION,
                component.good_id);
            if (rate <= 0) continue;
            const int64_t component_value = mul_div_sat(
                component_quantity(slot, component),
                _market.price[_market.index(market, component.good_id)],
                GOODS_SCALE, sat);
            quoted = saturating_add(quoted, mul_div_sat(
                component_value, rate, 100, sat), sat);
        }
        return std::max<int64_t>(1, quoted);
    };
    const auto full_consumption_subsidy = [&](const BundleOrder &order,
                                               int64_t units) {
        if (units <= 0) return int64_t{0};
        const int32_t cell = cohort_cell(order.slot);
        const VariantChoice &variant = _variants[order.variant_index];
        int64_t subsidy = 0;
        for (int32_t c = 0; c < variant.component_count; ++c) {
            const NeedComponent &component =
                _components[variant.component_begin + c];
            const int8_t rate = frozen_tax_rate(
                cell, NativeCountryRuntime::TAX_CONSUMPTION,
                component.good_id);
            if (rate >= 0) continue;
            const int64_t quantity = mul_div_sat(
                units, component_quantity(order.slot, component), GOODS_SCALE, sat);
            const int64_t component_base = mul_div_sat(
                quantity,
                _market.price[_market.index(market, component.good_id)],
                GOODS_SCALE, sat);
            subsidy = saturating_add(subsidy, mul_div_sat(
                component_base, -static_cast<int32_t>(rate), 100, sat), sat);
        }
        return subsidy;
    };
    const auto apply_subsidy_quotes = [&](std::vector<BundleOrder> &orders) {
        if (!subsidy_settlement) return;
        thread_local std::vector<int64_t> quoted_remaining;
        quoted_remaining.assign(static_cast<size_t>(_cell_count), 0);
        for (int32_t k = _market_cell_offsets[market];
             k < _market_cell_offsets[market + 1]; ++k) {
            const int32_t cell = _market_cells[k];
            const size_t lane = static_cast<size_t>(cell) *
                ACTIVE_TAX_KIND_COUNT + NativeCountryRuntime::TAX_CONSUMPTION;
            if (lane < _fiscal_remaining.size())
                quoted_remaining[cell] =
                    std::max<int64_t>(0, _fiscal_remaining[lane]);
        }
        for (BundleOrder &order : orders) {
            const int32_t cell = cohort_cell(order.slot);
            if (cell < 0 || cell >= _cell_count ||
                quoted_remaining[cell] <= 0 || order.desired_units <= 0)
                continue;
            int64_t allocated = 0;
            if (consumption_tax_active) {
                const int64_t full = full_consumption_subsidy(
                    order, order.desired_units);
                allocated = std::min(full, quoted_remaining[cell]);
                quoted_remaining[cell] -= allocated;
            }
            const int32_t pay = family_purchase_pay_factor_q16(order.slot);
            if (pay < Q16_ONE && quoted_remaining[cell] > 0) {
                const int64_t gross = mul_div_sat(
                    order.desired_units, order.unit_price, GOODS_SCALE, sat);
                const int64_t family_full = mul_div_sat(
                    gross, Q16_ONE - pay, Q16_ONE, sat);
                const int64_t family_alloc = std::min(
                    family_full, quoted_remaining[cell]);
                quoted_remaining[cell] -= family_alloc;
                allocated = saturating_add(allocated, family_alloc, sat);
            }
            if (allocated <= 0) continue;
            // Floor the per-unit discount so the quoted order budget is never
            // lower than the net cash ultimately charged at settlement.
            order.quoted_subsidy_per_unit = mul_div_sat(
                allocated, GOODS_SCALE, order.desired_units, sat);
            order.unit_price = std::max<int64_t>(
                1, saturating_sub(order.unit_price,
                                  order.quoted_subsidy_per_unit, sat));
        }
    };
    for (int32_t local = 0; local < cohort_count; ++local) {
        const int32_t slot = slots[local];
        const uint32_t signature_id = _population.signature_id[slot];
        if (signature_id >= _signatures.size()) {
            error = "cohort_signature_invalid";
            return false;
        }
        const Signature &signature = _signatures[signature_id];
        const Plan &plan = _plans[signature.plan_id];
        const int64_t population = std::max<int64_t>(0, _population.population[slot]);
        if (population <= 0) continue;
        for (int32_t n = 0; n < plan.need_count; ++n) {
            const int32_t need_index = plan.need_begin + n;
            const Need &need = _needs[need_index];
            // Frozen-sample approximation: calculate the whole market cycle
            // from the cohort/price/environment state captured at sample_day.
            const int64_t survival_required = survival_required_units(
                slot, need.stable_id, _epoch_days, market_environment, sat);
            if (need.stable_id >= 0 &&
                need.stable_id < static_cast<int32_t>(
                    _survival_food_need_mask.size()) &&
                _survival_food_need_mask[need.stable_id] != 0) {
                cohort_food_required[local] = saturating_add(
                    cohort_food_required[local], survival_required, sat);
            } else if (need.stable_id == _survival_clothing_need_stable_id) {
                cohort_clothing_required[local] = saturating_add(
                    cohort_clothing_required[local], survival_required, sat);
            }
            std::array<int64_t, MAX_VARIANTS_PER_NEED> cohort_variant_scores{};
            int64_t base_score_sum = 0;
            int64_t score_sum = 0;
            for (int32_t v = 0; v < need.variant_count; ++v) {
                const int32_t variant_id = need.variant_begin + v;
                if (approximation_apply &&
                    approximation_variant_active[variant_id] == 0) continue;
                const int64_t base_score = std::max<int64_t>(
                    0, variant_score_cache[variant_id]);
                base_score_sum = saturating_add(
                    base_score_sum, base_score, sat);
                const int64_t score = mul_div_sat(
                    base_score,
                    family_variant_preference_factor_q16(slot, variant_id, sat),
                    Q16_ONE, sat);
                cohort_variant_scores[v] = std::max<int64_t>(0, score);
                score_sum = saturating_add(
                    score_sum, cohort_variant_scores[v], sat);
            }
            if (score_sum <= 0) continue;
            int64_t ordinary_desired = desired_need_units(
                slot, need_index, _epoch_days, need_environment_cache[need_index],
                need_composite_cache[need_index], sat);
            if (base_score_sum > 0) {
                ordinary_desired = mul_div_sat(
                    ordinary_desired, score_sum, base_score_sum, sat);
            }
            const int64_t desired = std::max(ordinary_desired, survival_required);
            if (desired <= 0) continue;
            const int32_t state_index = static_cast<int32_t>(need_states.size());
            need_states.push_back({local, need_index, desired, 0, 0});
            cohort_desired[local] = saturating_add(cohort_desired[local], desired, sat);
            int64_t prefix_score = 0;
            int64_t allocated = 0;
            for (int32_t v = 0; v < need.variant_count; ++v) {
                const int32_t variant_id = need.variant_begin + v;
                if (approximation_apply &&
                    approximation_variant_active[variant_id] == 0) continue;
                prefix_score = saturating_add(
                    prefix_score, cohort_variant_scores[v], sat);
                const int64_t next = mul_div_sat(desired, prefix_score, score_sum, sat);
                const int64_t units = std::max<int64_t>(0, next - allocated);
                allocated = next;
                if (units > 0) {
                    const int64_t base_price =
                        variant_price_cache[variant_id];
                    primary_orders.push_back({local, slot, state_index, variant_id,
                                              need.priority, units, 0, 0,
                                              household_quote(slot, variant_id,
                                                  base_price),
                                              base_price, 0});
                }
            }
            ++result.processed_needs;
            result.processed_variants += need.variant_count;
        }
    }
    auto retained_begin = [&](int32_t owner_slot, int32_t good_id) {
        return std::lower_bound(
            _owner_retained_outputs.begin(), _owner_retained_outputs.end(),
            std::pair<int32_t, int32_t>{owner_slot, good_id},
            [](const OwnerRetainedOutput &entry, const std::pair<int32_t, int32_t> &key) {
                return std::pair<int32_t, int32_t>{entry.owner_slot, entry.good_id} < key;
        });
    };
    auto record_in_kind_value = [&](int32_t owner_slot, int32_t good_id,
                                    int32_t building_group, int64_t quantity) {
        if (quantity <= 0 || owner_slot < 0 || good_id < 0 ||
            good_id >= _market.good_count ||
            owner_slot >= static_cast<int32_t>(_population.active.size()) ||
            _population.active[owner_slot] == 0) return;
        const int32_t page = owner_slot / COHORT_PAGE_SIZE;
        if (page < 0 || page >= static_cast<int32_t>(_population.page_cell.size())) return;
        const int32_t cell = _population.page_cell[page];
        if (cell < 0 || cell >= static_cast<int32_t>(_market.cell_to_market.size())) return;
        const int32_t market = _market.cell_to_market[cell];
        if (market < 0 || market >= _market.market_count) return;
        const int64_t price = _market.price[_market.index(market, good_id)];
        const int64_t value = mul_div_sat(quantity, price, GOODS_SCALE, sat);
        _population.epoch_in_kind_income[owner_slot] = saturating_add(
            _population.epoch_in_kind_income[owner_slot], value, sat);
        if (building_group >= 0) {
            result.building_in_kind_credits.push_back({building_group, value});
        }
        result.retained_consumed_by_good[good_id] = saturating_add(
            result.retained_consumed_by_good[good_id], quantity, sat);
    };
    for (BundleOrder &order : primary_orders) {
        const VariantChoice &variant = _variants[order.variant_index];
        int64_t retained_capacity = order.desired_units;
        for (int32_t c = 0; c < variant.component_count; ++c) {
            const NeedComponent &component = _components[variant.component_begin + c];
            int64_t quantity = 0;
            auto found = retained_begin(order.slot, component.good_id);
            while (found != _owner_retained_outputs.end() &&
                   found->owner_slot == order.slot &&
                   found->good_id == component.good_id) {
                quantity = saturating_add(quantity, found->quantity, sat);
                ++found;
            }
            retained_capacity = std::min(retained_capacity, mul_div_sat(
                quantity, GOODS_SCALE,
                std::max<int64_t>(1, component_quantity(order.slot, component)), sat));
        }
        if (retained_capacity <= 0) continue;
        for (int32_t c = 0; c < variant.component_count; ++c) {
            const NeedComponent &component = _components[variant.component_begin + c];
            int64_t remaining = mul_div_sat(
                retained_capacity, component_quantity(order.slot, component),
                GOODS_SCALE, sat);
            auto found = retained_begin(order.slot, component.good_id);
            while (remaining > 0 && found != _owner_retained_outputs.end() &&
                   found->owner_slot == order.slot &&
                   found->good_id == component.good_id) {
                const int64_t used = std::min(remaining, found->quantity);
                found->quantity -= used;
                remaining -= used;
                record_in_kind_value(order.slot, component.good_id,
                                     found->building_group, used);
                ++found;
            }
            const int64_t used = mul_div_sat(
                retained_capacity, component_quantity(order.slot, component),
                GOODS_SCALE, sat) - remaining;
            result.retained_output_consumed = saturating_add(
                result.retained_output_consumed, used, sat);
        }
        need_states[order.need_index].filled_units = saturating_add(
            need_states[order.need_index].filled_units, retained_capacity, sat);
        order.desired_units -= retained_capacity;
    }
    // Exact plan variants consume retained output first. Any remaining
    // producer-retained food then acts as emergency calories across the three
    // survival food needs; preference still affects ordinary satisfaction, but
    // a hunter or fisher can live from the food it physically produced.
    for (int32_t local = 0; local < cohort_count; ++local) {
        int64_t food_filled = 0;
        for (const NeedState &state : need_states) {
            if (state.local_cohort != local) continue;
            const int32_t stable_need = _needs[state.need_index].stable_id;
            if (stable_need < 0 ||
                stable_need >= static_cast<int32_t>(
                    _survival_food_need_mask.size()) ||
                _survival_food_need_mask[stable_need] == 0) continue;
            food_filled = saturating_add(food_filled, state.filled_units, sat);
        }
        int64_t remaining = std::max<int64_t>(0, mul_div_sat(
            cohort_food_required[local], _survival_production_target_q16,
            Q16_ONE, sat) - food_filled);
        if (remaining <= 0) continue;
        auto entry = std::lower_bound(
            _owner_retained_outputs.begin(), _owner_retained_outputs.end(), slots[local],
            [](const OwnerRetainedOutput &value, int32_t owner_slot) {
                return value.owner_slot < owner_slot;
            });
        while (remaining > 0 && entry != _owner_retained_outputs.end() &&
               entry->owner_slot == slots[local]) {
            if (entry->good_id >= 0 &&
                entry->good_id < static_cast<int32_t>(_survival_food_good_mask.size()) &&
                _survival_food_good_mask[entry->good_id] != 0) {
                const int64_t used = std::min(remaining, entry->quantity);
                entry->quantity -= used;
                remaining -= used;
                record_in_kind_value(slots[local], entry->good_id,
                                     entry->building_group, used);
                cohort_subsistence_food_filled[local] = saturating_add(
                    cohort_subsistence_food_filled[local], used, sat);
                result.retained_output_consumed = saturating_add(
                    result.retained_output_consumed, used, sat);
            }
            ++entry;
        }
    }
    result.formula_ms += elapsed_ms(formula_start);

    auto budget_orders = [&](std::vector<BundleOrder> &orders, bool use_remaining) {
        thread_local std::vector<int64_t> budget_committed;
        budget_committed.assign(cohort_count, 0);
        size_t begin = 0;
        while (begin < orders.size()) {
            const int32_t local = orders[begin].local_cohort;
            const int32_t priority = orders[begin].priority;
            size_t end = begin + 1;
            while (end < orders.size() && orders[end].local_cohort == local &&
                   orders[end].priority == priority) ++end;
            int64_t remaining = std::max<int64_t>(
                0, _population.funds[slots[local]] -
                    cohort_working_capital_reserve[local] -
                    (use_remaining ? cohort_spend[local] : 0) -
                    budget_committed[local]);
            int64_t total_cost = 0;
            for (size_t i = begin; i < end; ++i) {
                total_cost = saturating_add(total_cost,
                    mul_div_sat(orders[i].desired_units, orders[i].unit_price,
                                GOODS_SCALE, sat), sat);
            }
            if (total_cost <= remaining) {
                for (size_t i = begin; i < end; ++i) orders[i].funded_units = orders[i].desired_units;
            } else if (remaining > 0 && total_cost > 0) {
                int64_t cost_prefix = 0;
                int64_t allocated_cost = 0;
                for (size_t i = begin; i < end; ++i) {
                    cost_prefix = saturating_add(cost_prefix,
                        mul_div_sat(orders[i].desired_units, orders[i].unit_price,
                                    GOODS_SCALE, sat), sat);
                    const int64_t next = mul_div_sat(cost_prefix, remaining, total_cost, sat);
                    const int64_t share = std::max<int64_t>(0, next - allocated_cost);
                    allocated_cost = next;
                    orders[i].funded_units = std::min(orders[i].desired_units,
                        mul_div_sat(share, GOODS_SCALE, orders[i].unit_price, sat));
                }
            }
            int64_t committed = 0;
            for (size_t i = begin; i < end; ++i) {
                committed = saturating_add(committed, mul_div_sat(
                    orders[i].funded_units, orders[i].unit_price,
                    GOODS_SCALE, sat), sat);
            }
            budget_committed[local] = saturating_add(
                budget_committed[local], committed, sat);
            begin = end;
        }
    };

    const auto record_order_settlement = [&](BundleOrder &order) {
        if (order.filled_units <= 0) return;
        if (!subsidy_settlement) {
            const int64_t spend = mul_div_sat(
                order.filled_units, order.unit_price, GOODS_SCALE, sat);
            cohort_spend[order.local_cohort] = saturating_add(
                cohort_spend[order.local_cohort], spend, sat);
            if (order.need_index >= 0 && order.need_index < static_cast<int32_t>(
                    need_states.size()))
                need_states[order.need_index].spent_money = saturating_add(
                    need_states[order.need_index].spent_money, spend, sat);
            return;
        }
        const int32_t cell = cohort_cell(order.slot);
        const VariantChoice &variant = _variants[order.variant_index];
        int64_t base_spend = 0;
        int64_t positive_tax = 0;
        int64_t subsidy = 0;
        for (int32_t c = 0; c < variant.component_count; ++c) {
            const NeedComponent &component =
                _components[variant.component_begin + c];
            const int64_t quantity = mul_div_sat(
                order.filled_units, component_quantity(order.slot, component),
                GOODS_SCALE, sat);
            const int64_t component_base = mul_div_sat(
                quantity, _market.price[_market.index(market, component.good_id)],
                GOODS_SCALE, sat);
            base_spend = saturating_add(base_spend, component_base, sat);
            const int8_t rate = frozen_tax_rate(
                cell, NativeCountryRuntime::TAX_CONSUMPTION,
                component.good_id);
            const int64_t transfer = apply_fiscal_tax(
                cell, NativeCountryRuntime::TAX_CONSUMPTION,
                component_base, rate, sat);
            if (transfer > 0)
                positive_tax = saturating_add(positive_tax, transfer, sat);
            else
                subsidy = saturating_add(subsidy, -transfer, sat);
        }
        const int32_t pay = family_purchase_pay_factor_q16(order.slot);
        if (pay < Q16_ONE && base_spend > 0) {
            const int64_t family_request = mul_div_sat(
                base_spend, Q16_ONE - pay, Q16_ONE, sat);
            const int64_t family_paid = -apply_fiscal_tax(
                cell, NativeCountryRuntime::TAX_CONSUMPTION,
                family_request, -100, sat);
            subsidy = saturating_add(subsidy, family_paid, sat);
        }
        cohort_base_spend[order.local_cohort] = saturating_add(
            cohort_base_spend[order.local_cohort], base_spend, sat);
        cohort_consumption_tax[order.local_cohort] = saturating_add(
            cohort_consumption_tax[order.local_cohort], positive_tax, sat);
        cohort_consumption_subsidy[order.local_cohort] = saturating_add(
            cohort_consumption_subsidy[order.local_cohort], subsidy, sat);
        const int64_t net_spend = saturating_sub(
            saturating_add(base_spend, positive_tax, sat), subsidy, sat);
        cohort_spend[order.local_cohort] = saturating_add(
            cohort_spend[order.local_cohort], net_spend, sat);
        if (order.need_index >= 0 && order.need_index < static_cast<int32_t>(
                need_states.size()))
            need_states[order.need_index].spent_money = saturating_add(
                need_states[order.need_index].spent_money, net_spend, sat);
    };
    auto clear_orders = [&](std::vector<BundleOrder> &orders) -> bool {
        good_counts.assign(_market.good_count, 0);
        pass_demand.assign(_market.good_count, 0);
        for (const BundleOrder &order : orders) {
            if (order.funded_units <= 0) continue;
            const VariantChoice &variant = _variants[order.variant_index];
            for (int32_t c = 0; c < variant.component_count; ++c) {
                const NeedComponent &component = _components[variant.component_begin + c];
                ++good_counts[component.good_id];
                const int64_t required = mul_div_sat(order.funded_units,
                    component_quantity(order.slot, component), GOODS_SCALE, sat);
                pass_demand[component.good_id] = saturating_add(
                    pass_demand[component.good_id], required, sat);
                good_demand[component.good_id] = saturating_add(
                    good_demand[component.good_id], required, sat);
                ++result.processed_components;
            }
        }
        bool abundant = true;
        for (int32_t good = 0; good < _market.good_count; ++good) {
            abundant &= std::max<int64_t>(0,
                _market.stock[_market.index(market, good)] -
                    production_input_floor[good]) >= pass_demand[good];
        }
        if (abundant) {
            for (BundleOrder &order : orders) {
                order.filled_units = order.funded_units;
                if (order.filled_units <= 0) continue;
                record_order_settlement(order);
                need_states[order.need_index].filled_units = saturating_add(
                    need_states[order.need_index].filled_units, order.filled_units, sat);
            }
            for (int32_t good = 0; good < _market.good_count; ++good) {
                const int64_t idx = _market.index(market, good);
                audit_touch_market_lane(static_cast<size_t>(idx));
                _market.stock[idx] -= pass_demand[good];
                good_sales[good] = saturating_add(good_sales[good], pass_demand[good], sat);
                result.consumed_goods = saturating_add(result.consumed_goods,
                                                       pass_demand[good], sat);
            }
            return true;
        }
        good_offsets.assign(_market.good_count + 1, 0);
        good_cursor.assign(_market.good_count, 0);
        for (int32_t good = 0; good < _market.good_count; ++good) {
            good_offsets[good + 1] = good_offsets[good] + good_counts[good];
            good_cursor[good] = good_offsets[good];
        }
        component_refs.assign(good_offsets.back(), {});
        for (int32_t o = 0; o < static_cast<int32_t>(orders.size()); ++o) {
            BundleOrder &order = orders[o];
            order.filled_units = order.funded_units;
            if (order.funded_units <= 0) continue;
            const VariantChoice &variant = _variants[order.variant_index];
            for (int32_t c = 0; c < variant.component_count; ++c) {
                const NeedComponent &component = _components[variant.component_begin + c];
                const int64_t adjusted_qty_per_need = std::max<int64_t>(1,
                    component_quantity(order.slot, component));
                const int64_t required = mul_div_sat(order.funded_units,
                    adjusted_qty_per_need, GOODS_SCALE, sat);
                component_refs[good_cursor[component.good_id]++] =
                    {o, required, adjusted_qty_per_need};
            }
        }
        for (int32_t good = 0; good < _market.good_count; ++good) {
            int64_t total = 0;
            for (int32_t k = good_offsets[good]; k < good_offsets[good + 1]; ++k) {
                total = saturating_add(total, component_refs[k].required_qty, sat);
            }
            const int64_t available = std::min<int64_t>(
                std::max<int64_t>(0, _market.stock[_market.index(market, good)] -
                    production_input_floor[good]), total);
            int64_t demand_prefix = 0;
            int64_t filled_prefix = 0;
            for (int32_t k = good_offsets[good]; k < good_offsets[good + 1]; ++k) {
                ComponentRef &ref = component_refs[k];
                demand_prefix = saturating_add(demand_prefix, ref.required_qty, sat);
                const int64_t next = total > 0
                    ? mul_div_sat(demand_prefix, available, total, sat) : 0;
                const int64_t allocated_qty = std::max<int64_t>(0, next - filled_prefix);
                filled_prefix = next;
                const int64_t bundle_capacity = mul_div_sat(
                    allocated_qty, GOODS_SCALE, ref.qty_per_need, sat);
                orders[ref.order].filled_units = std::min(
                    orders[ref.order].filled_units, bundle_capacity);
            }
        }
        pass_sales.assign(_market.good_count, 0);
        for (BundleOrder &order : orders) {
            if (order.filled_units <= 0) continue;
            const VariantChoice &variant = _variants[order.variant_index];
            for (int32_t c = 0; c < variant.component_count; ++c) {
                const NeedComponent &component = _components[variant.component_begin + c];
                const int64_t used = mul_div_sat(order.filled_units,
                    component_quantity(order.slot, component), GOODS_SCALE, sat);
                pass_sales[component.good_id] = saturating_add(pass_sales[component.good_id],
                                                               used, sat);
            }
            record_order_settlement(order);
            need_states[order.need_index].filled_units = saturating_add(
                need_states[order.need_index].filled_units, order.filled_units, sat);
        }
        for (int32_t good = 0; good < _market.good_count; ++good) {
            const int64_t idx = _market.index(market, good);
            const int64_t used = std::min(pass_sales[good], _market.stock[idx]);
            audit_touch_market_lane(static_cast<size_t>(idx));
            _market.stock[idx] -= used;
            good_sales[good] = saturating_add(good_sales[good], used, sat);
            result.consumed_goods = saturating_add(result.consumed_goods, used, sat);
        }
        return false;
    };

    const auto clear_start = Clock::now();
    apply_subsidy_quotes(primary_orders);
    budget_orders(primary_orders, false);
    const bool primary_inventory_abundant = clear_orders(primary_orders);
    result.clear_ms += elapsed_ms(clear_start);

    const auto fallback_start = Clock::now();
    // A fallback is a stock-substitution mechanism, not a second budget pass.
    // If every primary bundle was available, any unmet amount is budget-only.
    if (!primary_inventory_abundant) for (int32_t state_index = 0;
         state_index < static_cast<int32_t>(need_states.size()); ++state_index) {
        NeedState &state = need_states[state_index];
        const int64_t unmet = std::max<int64_t>(0, state.desired_units - state.filled_units);
        if (unmet <= 0) continue;
        const Need &need = _needs[state.need_index];
        int64_t score_sum = 0;
        for (int32_t v = 0; v < need.variant_count; ++v) {
            const int32_t variant_id = need.variant_begin + v;
            if (approximation_apply &&
                approximation_variant_active[variant_id] == 0) continue;
            const VariantChoice &variant = _variants[variant_id];
            bool available = true;
            for (int32_t c = 0; c < variant.component_count; ++c) {
                const NeedComponent &component = _components[variant.component_begin + c];
                available &= _market.stock[_market.index(market, component.good_id)] >
                    production_input_floor[component.good_id];
            }
            if (!available) continue;
            const int64_t score = mul_div_sat(
                variant_score_cache[variant_id],
                family_variant_preference_factor_q16(
                    slots[state.local_cohort], variant_id, sat),
                Q16_ONE, sat);
            if (score <= 0) continue;
            score_sum = saturating_add(score_sum, score, sat);
        }
        int64_t score_prefix = 0;
        int64_t allocated = 0;
        for (int32_t v = 0; v < need.variant_count && score_sum > 0; ++v) {
            const int32_t variant_id = need.variant_begin + v;
            if (approximation_apply &&
                approximation_variant_active[variant_id] == 0) continue;
            const VariantChoice &variant = _variants[variant_id];
            bool available = true;
            for (int32_t c = 0; c < variant.component_count; ++c) {
                const NeedComponent &component = _components[variant.component_begin + c];
                available &= _market.stock[_market.index(market, component.good_id)] >
                    production_input_floor[component.good_id];
            }
            const int64_t score = mul_div_sat(
                variant_score_cache[variant_id],
                family_variant_preference_factor_q16(
                    slots[state.local_cohort], variant_id, sat),
                Q16_ONE, sat);
            if (!available || score <= 0) continue;
            score_prefix = saturating_add(score_prefix, score, sat);
            const int64_t next = mul_div_sat(unmet, score_prefix, score_sum, sat);
            const int64_t units = std::max<int64_t>(0, next - allocated);
            allocated = next;
            if (units > 0) fallback_orders.push_back({
                state.local_cohort, slots[state.local_cohort], state_index, variant_id,
                need.priority, units, 0, 0,
                household_quote(slots[state.local_cohort], variant_id,
                    variant_price_cache[variant_id]),
                variant_price_cache[variant_id], 0});
        }
    }
    if (!primary_inventory_abundant) {
        apply_subsidy_quotes(fallback_orders);
        budget_orders(fallback_orders, true);
        clear_orders(fallback_orders);
    }

    for (int32_t slot : slots) {
        auto entry = std::lower_bound(
            _owner_retained_outputs.begin(), _owner_retained_outputs.end(), slot,
            [](const OwnerRetainedOutput &value, int32_t owner_slot) {
                return value.owner_slot < owner_slot;
            });
        while (entry != _owner_retained_outputs.end() && entry->owner_slot == slot) {
            result.retained_output_discarded = saturating_add(
                result.retained_output_discarded, entry->quantity, sat);
            if (entry->quantity > 0 && entry->building_group >= 0 &&
                entry->building_group < static_cast<int32_t>(_buildings.size())) {
                _buildings[entry->building_group].last_discarded = saturating_add(
                    _buildings[entry->building_group].last_discarded,
                    entry->quantity, sat);
            }
            entry->quantity = 0;
            ++entry;
        }
    }
    result.fallback_ms += elapsed_ms(fallback_start);

    const auto merchant_start = Clock::now();
    int64_t planned_revenue = 0;
    for (int32_t local = 0; local < cohort_count; ++local) {
        const int32_t slot = slots[local];
        const int64_t spend = std::min(cohort_spend[local], std::max<int64_t>(
            0, _population.funds[slot] - cohort_working_capital_reserve[local]));
        planned_revenue = saturating_add(planned_revenue,
            consumption_tax_active || subsidy_settlement ? cohort_base_spend[local] : spend, sat);
    }
    if (planned_revenue > 0 && living_merchants.empty()) {
        error = "market_revenue_has_no_merchant_owner";
        return false;
    }
    int64_t revenue = 0;
    for (int32_t local = 0; local < cohort_count; ++local) {
        const int32_t slot = slots[local];
        const int64_t spend = std::min(cohort_spend[local], std::max<int64_t>(
            0, _population.funds[slot] - cohort_working_capital_reserve[local]));
        _population.funds[slot] -= spend;
        _population.epoch_expense[slot] = saturating_add(
            _population.epoch_expense[slot], spend, sat);
        const int64_t subsidy = cohort_consumption_subsidy[local];
        record_cohort_fiscal(slot, cohort_consumption_tax[local]);
        record_cohort_fiscal(slot, -subsidy);
        if (trace_detail && spend > 0) {
            result.cashflows.push_back({_population.handle_for_slot(slot),
                CASHFLOW_HOUSEHOLD_CONSUMPTION, 0, spend});
        }
        if (trace_detail && cohort_consumption_tax[local] > 0)
            result.cashflows.push_back({_population.handle_for_slot(slot),
                CASHFLOW_CONSUMPTION_TAX, 0,
                cohort_consumption_tax[local]});
        if (trace_detail && subsidy > 0)
            result.cashflows.push_back({_population.handle_for_slot(slot),
                CASHFLOW_CONSUMPTION_SUBSIDY, subsidy, 0});
        revenue = saturating_add(revenue,
            consumption_tax_active || subsidy_settlement ? cohort_base_spend[local] : spend, sat);
    }
    int64_t merchant_population = 0;
    for (const int32_t slot : living_merchants) {
        merchant_population = saturating_add(merchant_population,
            _population.population[slot], sat);
    }
    if (revenue > 0 && merchant_population <= 0) {
        error = "market_revenue_has_no_merchant_owner";
        return false;
    }
    int64_t population_prefix = 0;
    int64_t distributed = 0;
    for (const int32_t slot : living_merchants) {
        population_prefix = saturating_add(population_prefix, _population.population[slot], sat);
        const int64_t next = merchant_population > 0
            ? mul_div_sat(revenue, population_prefix, merchant_population, sat) : 0;
        const int64_t share = std::max<int64_t>(0, next - distributed);
        distributed = next;
        int64_t income_tax = 0;
        if (income_tax_active) {
            const int32_t local = slot >= 0 &&
                    slot < static_cast<int32_t>(local_by_slot_stamp.size()) &&
                    local_by_slot_stamp[slot] == local_lookup_generation
                ? local_by_slot[slot] : -1;
            const int64_t household_expense = local >= 0
                ? cohort_spend[local] : 0;
            const int64_t operating_expense = std::max<int64_t>(
                0, _population.epoch_expense[slot] - household_expense);
            const int64_t taxable_income =
                std::max<int64_t>(0, share - operating_expense);
            const int32_t signature = static_cast<int32_t>(
                _population.signature_id[slot]);
            const int32_t profession = signature >= 0 &&
                    signature < static_cast<int32_t>(_signatures.size())
                ? _signatures[signature].profession_id : -1;
            const int32_t cell = cohort_cell(slot);
            const int8_t income_rate = frozen_tax_rate(
                cell, NativeCountryRuntime::TAX_INCOME, profession);
            if (income_rate < 0) {
                if (slot >= 0 && slot < static_cast<int32_t>(
                        _income_taxable_base_by_slot.size())) {
                    _income_taxable_base_by_slot[slot] = saturating_add(
                        _income_taxable_base_by_slot[slot], taxable_income,
                        sat);
                }
            } else {
                income_tax = apply_fiscal_tax(
                    cell, NativeCountryRuntime::TAX_INCOME, taxable_income,
                    income_rate, sat);
                record_cohort_fiscal(slot, income_tax);
            }
        }
        const int64_t net_share = saturating_sub(share, income_tax, sat);
        _population.funds[slot] = saturating_add(
            _population.funds[slot], net_share, sat);
        _population.epoch_income[slot] = saturating_add(
            _population.epoch_income[slot], share, sat);
        if (trace_detail && share > 0) {
            result.cashflows.push_back({_population.handle_for_slot(slot),
                CASHFLOW_MERCHANT_HOUSEHOLD, share, 0});
        }
        if (trace_detail && income_tax > 0)
            result.cashflows.push_back({_population.handle_for_slot(slot),
                CASHFLOW_INCOME_TAX, 0, income_tax});
        else if (trace_detail && income_tax < 0)
            result.cashflows.push_back({_population.handle_for_slot(slot),
                CASHFLOW_INCOME_SUBSIDY, -income_tax, 0});
    }
    result.merchant_count += static_cast<int64_t>(living_merchants.size());
    result.revenue = revenue;
    cohort_worst_q16.assign(cohort_count, Q16_ONE - 1);
    cohort_worst_need.assign(cohort_count, std::numeric_limits<uint16_t>::max());
    cohort_filled.assign(cohort_count, 0);
    if (trace_detail) {
        result.welfare_entries.resize(cohort_count);
        for (int32_t local = 0; local < cohort_count; ++local) {
            result.welfare_entries[local].cohort_handle =
                _population.handle_for_slot(slots[local]);
        }
    }
    for (const NeedState &state : need_states) {
        const int32_t local = state.local_cohort;
        cohort_filled[local] = saturating_add(cohort_filled[local], state.filled_units, sat);
        const int32_t stable_need = _needs[state.need_index].stable_id;
        if (stable_need >= 0 &&
            static_cast<size_t>(stable_need) < _need_carrying_family.size()) {
            const int32_t family = _need_carrying_family[static_cast<size_t>(stable_need)];
            if (family >= 0 && family < 3) {
                food_family_filled[static_cast<size_t>(family)] = saturating_add(
                    food_family_filled[static_cast<size_t>(family)],
                    state.filled_units, sat);
                food_family_desired[static_cast<size_t>(family)] = saturating_add(
                    food_family_desired[static_cast<size_t>(family)],
                    state.desired_units, sat);
            }
        }
        if (stable_need >= 0 &&
            stable_need < static_cast<int32_t>(
                _survival_food_need_mask.size()) &&
            _survival_food_need_mask[stable_need] != 0) {
            cohort_food_filled[local] = saturating_add(
                cohort_food_filled[local], state.filled_units, sat);
        } else if (stable_need == _survival_clothing_need_stable_id) {
            cohort_clothing_filled[local] = saturating_add(
                cohort_clothing_filled[local], state.filled_units, sat);
        }
        const int64_t satisfaction = state.desired_units <= 0
            ? Q16_ONE - 1
            : std::clamp<int64_t>(mul_div_sat(state.filled_units, Q16_ONE,
                                              state.desired_units, sat), 0, Q16_ONE - 1);
        if (stable_need >= 0 &&
            stable_need < static_cast<int32_t>(_survival_food_need_mask.size()) &&
            _survival_food_need_mask[stable_need] != 0) {
            // Any complete food sub-basket is caloric evidence. Protein is not
            // a decorative luxury: a fully satisfied fish/meat basket keeps a
            // cohort alive even when the preferred staple basket is empty.
            cohort_best_food_q16[local] = std::max(
                cohort_best_food_q16[local], satisfaction);
        }
        const Need &need = _needs[state.need_index];
        const int64_t tier_weight = need.satisfaction_weight_q16;
        if (tier_weight > 0) {
            const size_t tier_index = static_cast<size_t>(local) * SAT_TIER_COUNT +
                static_cast<size_t>(need.satisfaction_tier);
            cohort_tier_weighted_q16[tier_index] = saturating_add(
                cohort_tier_weighted_q16[tier_index],
                saturating_mul(satisfaction, tier_weight, sat), sat);
            cohort_tier_weight_q16[tier_index] = saturating_add(
                cohort_tier_weight_q16[tier_index], tier_weight, sat);
        }
        if (trace_detail) {
            CohortWelfareEntry &entry = result.welfare_entries[local];
            entry.need_ids.push_back(stable_need);
            entry.need_satisfaction_q16.push_back(static_cast<int32_t>(satisfaction));
            entry.need_weight_q16.push_back(static_cast<int32_t>(tier_weight));
            entry.need_tiers.push_back(static_cast<int32_t>(need.satisfaction_tier));
        }
        if (satisfaction < cohort_worst_q16[local]) {
            cohort_worst_q16[local] = satisfaction;
            cohort_worst_need[local] = static_cast<uint16_t>(_needs[state.need_index].stable_id);
        }
    }
    // Sparse post-settlement attribution. Important people do not submit
    // orders; they inherit the cohort's realized need satisfaction and receive
    // a deterministic share of the actual buyer outflow.
    if (_person_runtime_mode == 2 &&
        _person_cohort_offsets.size() == _population.active.size() + 1) {
        thread_local std::vector<int32_t> local_persons;
        thread_local std::vector<int64_t> person_weights;
        for (int32_t local = 0; local < cohort_count; ++local) {
            const int32_t slot = slots[local];
            const int32_t begin_person = _person_cohort_offsets[slot];
            const int32_t end_person = _person_cohort_offsets[slot + 1];
            if (begin_person >= end_person) continue;
            local_persons.clear();
            for (int32_t p = begin_person; p < end_person; ++p) {
                const int32_t person = _person_cohort_indices[p];
                if (_persons.active[person] == 0) continue;
                local_persons.push_back(person);
                result.person_attributions.push_back({
                    _persons.handle_for_index(person), 0, 0,
                    static_cast<uint16_t>(cohort_worst_q16[local]),
                    cohort_worst_need[local]});
            }
            const size_t attr_begin = result.person_attributions.size() -
                local_persons.size();
            for (const NeedState &state : need_states) {
                if (state.local_cohort != local) continue;
                const int32_t stable_need = _needs[state.need_index].stable_id;
                const int64_t satisfaction = state.desired_units <= 0
                    ? Q16_ONE - 1
                    : std::clamp<int64_t>(mul_div_sat(state.filled_units,
                        Q16_ONE, state.desired_units, sat), 0, Q16_ONE - 1);
                person_weights.assign(local_persons.size(), 0);
                int64_t notable_weight = 0;
                for (size_t pi = 0; pi < local_persons.size(); ++pi) {
                    const int32_t person = local_persons[pi];
                    const int64_t funds = person < static_cast<int32_t>(
                            _person_opening_cash_claim.size())
                        ? _person_opening_cash_claim[person]
                        : _persons.cash_claim[person];
                    int64_t desired = desired_need_units_for_actor(
                        slot, state.need_index, _epoch_days,
                        need_environment_cache[state.need_index],
                        need_composite_cache[state.need_index], 1, funds, sat);
                    const int64_t cohort_population = std::max<int64_t>(
                        1, _population.population[slot]);
                    const int64_t survival_share = std::max<int64_t>(0,
                        survival_required_units(slot, stable_need, _epoch_days,
                            market_environment, sat) / cohort_population);
                    desired = std::max(desired, survival_share);
                    person_weights[pi] = desired;
                    notable_weight = saturating_add(notable_weight, desired, sat);
                }
                const int64_t denominator = std::max<int64_t>(
                    state.desired_units, notable_weight);
                int64_t prefix_weight = 0, distributed_spend = 0;
                for (size_t pi = 0; pi < local_persons.size(); ++pi) {
                    prefix_weight = saturating_add(prefix_weight,
                        person_weights[pi], sat);
                    const int64_t next_spend = denominator > 0
                        ? mul_div_sat(state.spent_money, prefix_weight,
                            denominator, sat) : 0;
                    const int64_t share = std::max<int64_t>(0,
                        next_spend - distributed_spend);
                    distributed_spend = next_spend;
                    const int32_t person = local_persons[pi];
                    result.person_needs.push_back({
                        _persons.handle_for_index(person), stable_need,
                        person_weights[pi], static_cast<uint16_t>(satisfaction),
                        share});
                    result.person_attributions[attr_begin + pi].consumption_expense =
                        saturating_add(result.person_attributions[
                            attr_begin + pi].consumption_expense, share, sat);
                }
            }
            const int64_t cohort_outflow = std::max<int64_t>(
                1, cohort_spend[local]);
            int64_t expense_prefix = 0, distributed_tax = 0;
            for (size_t pi = 0; pi < local_persons.size(); ++pi) {
                PersonMarketAttribution &attribution =
                    result.person_attributions[attr_begin + pi];
                expense_prefix = saturating_add(expense_prefix,
                    attribution.consumption_expense, sat);
                const int64_t next_tax = mul_div_sat(
                    cohort_consumption_tax[local], expense_prefix,
                    cohort_outflow, sat);
                attribution.consumption_tax = std::max<int64_t>(
                    0, next_tax - distributed_tax);
                distributed_tax = next_tax;
            }
        }
    }
    int64_t remaining_market_population = 0;
    for (int32_t slot : slots) remaining_market_population = saturating_add(
        remaining_market_population, std::max<int64_t>(0, _population.population[slot]), sat);
    int64_t sat_cell_num = 0;
    int64_t sat_cell_den = 0;
    for (int32_t local = 0; local < cohort_count; ++local) {
        const int32_t slot = slots[local];
        cohort_food_filled[local] = saturating_add(
            cohort_food_filled[local], cohort_subsistence_food_filled[local], sat);
        const int64_t balanced_food_q16 = cohort_food_required[local] <= 0 ? Q16_ONE - 1
            : std::clamp<int64_t>(mul_div_sat(
                cohort_food_filled[local], Q16_ONE, cohort_food_required[local], sat),
                0, Q16_ONE - 1);
        // The three food needs are preference/price sub-baskets, not mutually
        // exclusive starvation gates. A complete protein or produce basket is
        // sufficient evidence of calories, just like a complete staple basket.
        const int64_t food_q16 = std::max(
            balanced_food_q16, cohort_best_food_q16[local]);
        const int64_t clothing_q16 = cohort_clothing_required[local] <= 0 ? Q16_ONE - 1
            : std::clamp<int64_t>(mul_div_sat(
                cohort_clothing_filled[local], Q16_ONE,
                cohort_clothing_required[local], sat), 0, Q16_ONE - 1);
        const int32_t cell = _population.page_cell[slot / COHORT_PAGE_SIZE];
        const int64_t temperature_q16 = cell >= 0 && cell < _cell_count
            ? _environment_temperature_q16[cell] : Q16_ONE / 2;
        const int64_t snow_q16 = cell >= 0 && cell < _cell_count
            ? _environment_snow_q16[cell] : 0;
        const int64_t temperature_exposure_q16 = std::clamp<int64_t>(
            (Q16_ONE / 2 - temperature_q16) * 2, 0, Q16_ONE);
        const int64_t cold_exposure_q16 = std::max<int64_t>(
            temperature_exposure_q16, std::clamp<int64_t>(snow_q16, 0, Q16_ONE));
        const int64_t clothing_deficit_q16 = Q16_ONE - clothing_q16;
        const int64_t cold_clothing_ceiling_q16 = Q16_ONE - mul_div_sat(
            cold_exposure_q16, clothing_deficit_q16, Q16_ONE, sat);
        const int64_t survival_q16 = std::min(food_q16, cold_clothing_ceiling_q16);
        _population.needs_satisfaction[slot] = static_cast<uint16_t>(survival_q16);
        _population.worst_need_id[slot] = cohort_worst_need[local];
        const int64_t net_income = saturating_sub(_population.epoch_income[slot],
                                                  _population.epoch_expense[slot], sat);
        const int64_t daily_net_income = net_income / std::max(1, _epoch_days);
        const int64_t income_alpha_q16 = std::min<int64_t>(
            Q16_ONE, static_cast<int64_t>(_epoch_days) * (Q16_ONE / 8));
        _population.income_ema[slot] = saturating_add(
            mul_div_sat(_population.income_ema[slot], Q16_ONE - income_alpha_q16,
                        Q16_ONE, sat),
            mul_div_sat(daily_net_income, income_alpha_q16, Q16_ONE, sat), sat);
        const int64_t baseline_alpha_q16 = std::min<int64_t>(
            Q16_ONE, static_cast<int64_t>(_epoch_days) *
                _satisfaction_income_baseline_alpha_q16);
        _population.income_baseline_ema[slot] = saturating_add(
            mul_div_sat(_population.income_baseline_ema[slot],
                        Q16_ONE - baseline_alpha_q16, Q16_ONE, sat),
            mul_div_sat(daily_net_income, baseline_alpha_q16, Q16_ONE, sat), sat);

        const uint32_t signature_id = _population.signature_id[slot];
        const Signature &signature = _signatures[signature_id];
        const int64_t composite_q16 = update_cohort_satisfaction(
            slot, cell, survival_q16, signature,
            &cohort_tier_weighted_q16[static_cast<size_t>(local) * SAT_TIER_COUNT],
            &cohort_tier_weight_q16[static_cast<size_t>(local) * SAT_TIER_COUNT],
            sat);
        if (trace_detail && local < static_cast<int32_t>(
                result.welfare_entries.size())) {
            CohortWelfareEntry &entry = result.welfare_entries[local];
            entry.overall_satisfaction_q16 = static_cast<int32_t>(composite_q16);
            entry.living_standard_level = living_standard_level_for(composite_q16);
            entry.worst_dimension_id = _population.worst_dimension_id[slot] ==
                    std::numeric_limits<uint8_t>::max()
                ? -1 : static_cast<int32_t>(_population.worst_dimension_id[slot]);
            const size_t dims_base = static_cast<size_t>(slot) *
                static_cast<size_t>(SAT_DIM_COUNT);
            for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
                entry.satisfaction_dims_q16[static_cast<size_t>(dim)] =
                    _population.satisfaction_dims[dims_base +
                                                  static_cast<size_t>(dim)];
        }
        const int64_t rescale_q16 = std::clamp<int64_t>(
            mul_div_sat(composite_q16, Q16_ONE,
                        std::max(1, _satisfaction_birth_reference_q16), sat),
            _carrying_sat_floor_q16, _carrying_sat_cap_q16);
        cohort_rescale_sat_q16[static_cast<size_t>(local)] = rescale_q16;
        int32_t class_weight = Q16_ONE;
        if (signature.profession_id >= 0 &&
            signature.profession_id < static_cast<int32_t>(
                _profession_class_index.size())) {
            const int32_t class_index =
                _profession_class_index[static_cast<size_t>(signature.profession_id)];
            if (class_index >= 0 && class_index < static_cast<int32_t>(
                    _carrying_class_weight_q16.size())) {
                class_weight = std::max(1,
                    _carrying_class_weight_q16[static_cast<size_t>(class_index)]);
            }
        }
        const int64_t pop = std::max<int64_t>(0, _population.population[slot]);
        sat_cell_num = saturating_add(sat_cell_num, saturating_mul(
            saturating_mul(pop, class_weight, sat), rescale_q16, sat), sat);
        sat_cell_den = saturating_add(sat_cell_den,
            saturating_mul(pop, class_weight, sat), sat);
    }
    const int32_t birth_cell = _market_cell_offsets[market] <
            _market_cell_offsets[market + 1]
        ? _market_cells[_market_cell_offsets[market]] : market;
    int64_t surplus_num = 0;
    int64_t surplus_den = 0;
    const size_t family_base = static_cast<size_t>(std::max(0, birth_cell)) *
        CARRYING_FAMILY_COUNT;
    if (family_base + CARRYING_FAMILY_COUNT <= _cell_carrying_family_surplus_q16.size() &&
        family_base + CARRYING_FAMILY_COUNT <= _cell_carrying_family_bindable.size()) {
        std::fill(_cell_carrying_family_surplus_q16.begin() + family_base,
                  _cell_carrying_family_surplus_q16.begin() + family_base +
                      CARRYING_FAMILY_COUNT,
                  static_cast<int32_t>(Q16_ONE));
        std::fill(_cell_carrying_family_bindable.begin() + family_base,
                  _cell_carrying_family_bindable.begin() + family_base +
                      CARRYING_FAMILY_COUNT,
                  0);
    }
    for (int32_t family = 0; family < CARRYING_FAMILY_COUNT; ++family) {
        const int64_t food_filled = family < 3
            ? food_family_filled[static_cast<size_t>(family)] : 0;
        const int64_t food_desired = family < 3
            ? food_family_desired[static_cast<size_t>(family)] : 0;
        const int64_t family_surplus = cell_family_surplus_q16(
            market, birth_cell, family, food_filled, food_desired,
            good_demand.data(), good_sales.data(), sat);
        const int32_t weight = family < static_cast<int32_t>(_carrying_family_weight.size())
            ? std::max(0, _carrying_family_weight[static_cast<size_t>(family)]) : 0;
        if (family_base + static_cast<size_t>(family) <
            _cell_carrying_family_surplus_q16.size()) {
            _cell_carrying_family_surplus_q16[family_base + static_cast<size_t>(family)] =
                family_surplus < 0 ? Q16_ONE : static_cast<int32_t>(family_surplus);
            _cell_carrying_family_bindable[family_base + static_cast<size_t>(family)] =
                family_surplus < 0 ? 0 : 1;
        }
        if (family_surplus < 0 || weight <= 0) continue;
        surplus_num = saturating_add(surplus_num,
            saturating_mul(family_surplus, weight, sat), sat);
        surplus_den = saturating_add(surplus_den, weight, sat);
    }
    const int64_t surplus_q16 = surplus_den > 0
        ? mul_div_sat(surplus_num, 1, surplus_den, sat) : Q16_ONE;
    const int64_t sat_cell_q16 = sat_cell_den > 0
        ? std::clamp<int64_t>(mul_div_sat(sat_cell_num, 1, sat_cell_den, sat),
                              _carrying_sat_floor_q16, _carrying_sat_cap_q16)
        : Q16_ONE;
    const int64_t k_geo = cell_k_geo_persons(birth_cell, sat);
    const int64_t mix_factor = mul_div_sat(
        carrying_mix_q16(surplus_q16, _carrying_surplus_elasticity_q16, sat),
        carrying_mix_q16(sat_cell_q16, _carrying_sat_elasticity_q16, sat),
        Q16_ONE, sat);
    int32_t ema_fallback = Q16_ONE;
    int32_t *support_ema_ptr = birth_cell >= 0 &&
            static_cast<size_t>(birth_cell) < _cell_support_ema_q16.size()
        ? &_cell_support_ema_q16[static_cast<size_t>(birth_cell)]
        : &ema_fallback;
    const int64_t ema_alpha = std::min<int64_t>(
        Q16_ONE, static_cast<int64_t>(_epoch_days) * _carrying_support_ema_alpha_q16);
    *support_ema_ptr = static_cast<int32_t>(saturating_add(
        mul_div_sat(*support_ema_ptr, Q16_ONE - ema_alpha, Q16_ONE, sat),
        mul_div_sat(mix_factor, ema_alpha, Q16_ONE, sat), sat));
    const int64_t k_eff = std::max<int64_t>(1, mul_div_sat(
        k_geo, std::max<int64_t>(1, static_cast<int64_t>(*support_ema_ptr)),
        Q16_ONE, sat));
    if (birth_cell >= 0 && static_cast<size_t>(birth_cell) < _cell_carrying_k_geo.size()) {
        _cell_carrying_k_geo[static_cast<size_t>(birth_cell)] = k_geo;
        _cell_carrying_k_eff[static_cast<size_t>(birth_cell)] = k_eff;
        _cell_carrying_surplus_q16[static_cast<size_t>(birth_cell)] =
            static_cast<int32_t>(surplus_q16);
        _cell_carrying_sat_q16[static_cast<size_t>(birth_cell)] =
            static_cast<int32_t>(sat_cell_q16);
    }
    const int64_t load_q16 = mul_div_sat(
        remaining_market_population, Q16_ONE, k_eff, sat);
    for (int32_t local = 0; local < cohort_count; ++local) {
        const int32_t slot = slots[local];
        const uint32_t signature_id = _population.signature_id[slot];
        const Signature &signature = _signatures[signature_id];
        const int32_t cell = _population.page_cell[slot / COHORT_PAGE_SIZE];
        const int64_t survival_q16 = _population.needs_satisfaction[slot];
        if (signature.ethnicity_id >= 0 && signature.ethnicity_id <
                static_cast<int32_t>(expected_births_q32_by_ethnicity.size())) {
            int64_t fertility_land_q16 = Q16_ONE;
            if (load_q16 > _carrying_soft_start_q16) {
                const int64_t replacement_q16 = std::clamp<int64_t>(
                    mul_div_sat(std::max<int64_t>(0, signature.death_rate_q32),
                                Q16_ONE,
                                std::max<int64_t>(1, signature.birth_rate_q32), sat),
                    0, Q16_ONE);
                const int64_t span = std::max<int64_t>(
                    1, Q16_ONE - _carrying_soft_start_q16);
                const int64_t t_q16 = std::clamp<int64_t>(
                    mul_div_sat(load_q16 - _carrying_soft_start_q16, Q16_ONE,
                                span, sat), 0, Q16_ONE);
                fertility_land_q16 = saturating_add(Q16_ONE, mul_div_sat(
                    t_q16, replacement_q16 - Q16_ONE, Q16_ONE, sat), sat);
            }
            const int64_t rescale_q16 = cohort_rescale_sat_q16[static_cast<size_t>(local)];
            const int64_t residual_q16 = std::clamp<int64_t>(
                mul_div_sat(rescale_q16, Q16_ONE,
                            std::max<int64_t>(1, sat_cell_q16), sat),
                _carrying_residual_floor_q16, _carrying_residual_cap_q16);
            int64_t effective_birth_rate_q32 = mul_div_sat(
                mul_div_sat(std::max<int64_t>(0, signature.birth_rate_q32),
                            fertility_land_q16, Q16_ONE, sat),
                residual_q16, Q16_ONE, sat);
            if (cell >= 0 && cell < static_cast<int32_t>(
                    _epoch_cell_birth_factor_q16.size())) {
                effective_birth_rate_q32 = mul_div_sat(
                    effective_birth_rate_q32,
                    _epoch_cell_birth_factor_q16[cell], Q16_ONE, sat);
            }
            if (_family_cohort_offsets.size() == _population.active.size() + 1 &&
                !_family_birth_factor_q16.empty()) {
                const int64_t cohort_population = std::max<int64_t>(1,
                    _population.population[slot]);
                int64_t weighted = saturating_mul(cohort_population, Q16_ONE, sat);
                for (int32_t p = _family_cohort_offsets[slot];
                     p < _family_cohort_offsets[slot + 1]; ++p) {
                    const FamilyMembershipEdge &edge = _family_memberships[
                        _family_cohort_edge_indices[p]];
                    if (edge.people <= 0 || edge.family_handle == 0) continue;
                    int32_t family = -1;
                    if (!_families.valid_handle(edge.family_handle, family) ||
                        family < 0 || family >= static_cast<int32_t>(
                            _family_birth_factor_q16.size()))
                        continue;
                    const int32_t factor = _family_birth_factor_q16[
                        static_cast<size_t>(family)];
                    if (factor == Q16_ONE) continue;
                    weighted = saturating_add(weighted,
                        saturating_mul(edge.people,
                            static_cast<int64_t>(factor) - Q16_ONE, sat), sat);
                }
                const int64_t mix = mul_div_sat(weighted, 1, cohort_population, sat);
                effective_birth_rate_q32 = mul_div_sat(
                    effective_birth_rate_q32, mix, Q16_ONE, sat);
            }
            const int64_t expected_births_q32 = saturating_mul(
                saturating_mul(std::max<int64_t>(0, _population.population[slot]),
                               effective_birth_rate_q32, sat),
                std::max(1, _epoch_days), sat);
            expected_births_q32_by_ethnicity[signature.ethnicity_id] = saturating_add(
                expected_births_q32_by_ethnicity[signature.ethnicity_id],
                expected_births_q32, sat);
        }
        // Invariant: starvation mortality reads SAT_DIM_SUBSISTENCE and nothing
        // else. Dying of hunger is a physiological fact, so a heavy tax burden,
        // an empty purse, or a backward settlement must never kill anyone here.
        const int64_t survival_deficit = std::max<int64_t>(
            0, _starvation_satisfaction_threshold_q16 - survival_q16);
        const int64_t starvation_rate_q32 = mul_div_sat(
            _starvation_death_rate_q32, survival_deficit,
            _starvation_satisfaction_threshold_q16, sat);
        const int64_t effective_death_rate_q32 = saturating_add(
            signature.death_rate_q32, starvation_rate_q32, sat);
        int64_t death_numerator_q32 = saturating_add(
            _population.demography_residual[slot], saturating_mul(
                saturating_mul(std::max<int64_t>(0, _population.population[slot]),
                               effective_death_rate_q32, sat),
                std::max(1, _epoch_days), sat), sat);
        int64_t deaths = death_numerator_q32 / Q32_ONE;
        const int64_t population_before = std::max<int64_t>(0, _population.population[slot]);
        const int64_t market_survivor_floor = remaining_market_population <= population_before ? 1 : 0;
        deaths = std::clamp<int64_t>(deaths, 0,
            std::max<int64_t>(0, population_before - market_survivor_floor));
        _population.demography_residual[slot] = deaths >= population_before
            ? 0 : death_numerator_q32 % Q32_ONE;
        if (deaths > 0) {
            if (_person_runtime_mode == 2 &&
                _person_cohort_offsets.size() == _population.active.size() + 1 &&
                _person_cohort_offsets[slot] < _person_cohort_offsets[slot + 1])
                result.person_demography.push_back({
                    _population.handle_for_slot(slot), population_before, deaths});
            _population.population[slot] -= deaths;
            population_changed = true;
            remaining_market_population -= deaths;
            result.deaths = saturating_add(result.deaths, deaths, sat);
            if (_population.population[slot] == 0) {
                result.structural_commands.push_back({
                    0, slot, cell, static_cast<int32_t>(signature_id), 0, 0, _epoch_id});
            }
        }
    }
    if (population_changed) result.population_changed_cells.push_back(birth_cell);
    for (int32_t ethnicity = 0; ethnicity <
            static_cast<int32_t>(expected_births_q32_by_ethnicity.size()); ++ethnicity) {
        const int64_t expected_q32 = expected_births_q32_by_ethnicity[ethnicity];
        if (expected_q32 <= 0) continue;
        const size_t residual_lane = static_cast<size_t>(birth_cell) *
            _ethnicity_ids.size() + static_cast<size_t>(ethnicity);
        const int64_t accumulated_q32 = saturating_add(
            _birth_residual_q32[residual_lane], expected_q32, sat);
        const int64_t births = accumulated_q32 / Q32_ONE;
        _birth_residual_q32[residual_lane] = accumulated_q32 % Q32_ONE;
        if (births <= 0) continue;
        const int32_t unemployed_signature = unemployed_signature_for_ethnicity(ethnicity);
        if (unemployed_signature < 0) {
            error = "birth_unemployed_signature_missing";
            return false;
        }
        result.births = saturating_add(result.births, births, sat);
        result.structural_commands.push_back({
            STRUCTURAL_BIRTH, -1, birth_cell, unemployed_signature,
            births, 0, _epoch_id});
    }
    result.merchant_settle_ms += elapsed_ms(merchant_start);

    const auto price_start = Clock::now();
    for (int32_t good = 0; good < _market.good_count; ++good) {
        const int64_t idx = _market.index(market, good);
        const int64_t old_ema = _market.demand_ema[idx];
        const int64_t daily_demand = good_demand[good] / std::max(1, _epoch_days);
        const int64_t alpha = std::min<int64_t>(Q16_ONE,
            static_cast<int64_t>(std::clamp<int32_t>(
                _good_demand_ema_alpha_q16[good], 0, Q16_ONE)) * _epoch_days);
        const int64_t ema = saturating_add(
            mul_div_sat(old_ema, Q16_ONE - alpha, Q16_ONE, sat),
            mul_div_sat(daily_demand, alpha, Q16_ONE, sat), sat);
        _market.demand_ema[idx] = ema;
        const int32_t signal_index = market_signal_index(market, good);
        if (signal_index >= 0) {
            const int64_t nonhousehold = signal_index < static_cast<int32_t>(
                    _epoch_nonhousehold_withdrawals.size())
                ? _epoch_nonhousehold_withdrawals[signal_index] : 0;
            const int64_t observed_daily = saturating_add(
                saturating_add(good_sales[good], nonhousehold, sat),
                result.retained_consumed_by_good[good], sat) /
                std::max(1, _epoch_days);
            const int64_t old_withdrawal =
                _market_signals.realized_withdrawal_ema[signal_index];
            _market_signals.realized_withdrawal_ema[signal_index] = saturating_add(
                mul_div_sat(old_withdrawal, Q16_ONE - alpha, Q16_ONE, sat),
                mul_div_sat(observed_daily, alpha, Q16_ONE, sat), sat);
        }
        const int64_t shortage = good_demand[good] <= 0 ? 0 : std::clamp<int64_t>(
            Q16_ONE - mul_div_sat(good_sales[good], Q16_ONE, good_demand[good], sat),
            0, Q16_ONE);
        _market.last_shortage_q16[idx] = static_cast<uint16_t>(
            std::min<int64_t>(Q16_ONE - 1, shortage));
        const PricePressure pressure = price_pressure(
            market, good, ema, _market.stock[idx], shortage, signal_index, sat);
        if (pressure.cost_q16 != 0) ++result.price_cost_anchor_hits;
        if (pressure.idle_q16 != 0) ++result.price_inactive_reversions;
        bool rate_clamped = false;
        const int64_t next_price = next_price_v4(good, _market.price[idx], pressure,
            _epoch_days, sat, rate_clamped);
        // The catalog bounds are gameplay/economic invariants, while the
        // numeric guard only protects the storage type.  Applying only the
        // latter lets inactive goods collapse to one sub-unit and appear as
        // a zero price in the UI.
        const int64_t catalog_min = std::max<int64_t>(
            PRICE_NUMERIC_GUARD_MIN, _good_min_price[good]);
        const int64_t catalog_max = std::min<int64_t>(
            PRICE_NUMERIC_GUARD_MAX, std::max<int64_t>(catalog_min, _good_max_price[good]));
        const int64_t bounded = std::clamp<int64_t>(
            next_price, catalog_min, catalog_max);
        if (rate_clamped || bounded != next_price) ++result.price_cap_hits;
        if (_market.price[idx] != bounded) ++result.changed_prices;
        _market.price[idx] = static_cast<int32_t>(bounded);
        const int32_t flow_index = trade_flow_index(market, good, false);
        if (_good_trade_enabled[good] != 0 && _good_storage_modes[good] == 0 &&
            (_market.stock[idx] > 0 || ema > 0 || shortage > 0 || signal_index >= 0 ||
             flow_index >= 0)) {
            result.trade_active_goods.push_back(good);
        }
    }
    result.mutation_hash = trace_hash_mix(result.mutation_hash,
                                          static_cast<uint64_t>(result.revenue));
    result.mutation_hash = trace_hash_mix(result.mutation_hash,
                                          static_cast<uint64_t>(result.consumed_goods));
    result.mutation_hash = trace_hash_mix(result.mutation_hash,
                                          static_cast<uint64_t>(result.changed_prices));
    result.mutation_hash = trace_hash_mix(result.mutation_hash,
                                          static_cast<uint64_t>(result.price_cap_hits));
    if (trace_detail) {
        const EnvironmentSample attribution_environment = environment_sample_for_cell(market);
        for (int32_t local = 0; local < cohort_count; ++local) {
            const int32_t slot = slots[local];
            CohortWelfareEntry &entry = result.welfare_entries[local];
            std::vector<int64_t> previous;
            std::vector<int64_t> wealth_only;
            std::vector<int64_t> current;
            compute_cohort_demand_preview(slot, market, attribution_environment,
                &trace_price_before, trace_funds_before[local], previous, sat);
            compute_cohort_demand_preview(slot, market, attribution_environment,
                &trace_price_before, _population.funds[slot], wealth_only, sat);
            compute_cohort_demand_preview(slot, market, attribution_environment,
                nullptr, _population.funds[slot], current, sat);
            entry.previous_demand_per_capita_daily = previous;
            entry.wealth_demand_delta_per_capita_daily.resize(_market.good_count, 0);
            entry.price_demand_delta_per_capita_daily.resize(_market.good_count, 0);
            for (int32_t good = 0; good < _market.good_count; ++good) {
                entry.wealth_demand_delta_per_capita_daily[good] =
                    wealth_only[good] - previous[good];
                entry.price_demand_delta_per_capita_daily[good] =
                    current[good] - wealth_only[good];
            }
        }
        auto add_leg = [&](int32_t field, int32_t subject_kind, int64_t subject_id,
                           int32_t key_id, int64_t before, int64_t after) {
            if (before != after) result.trace_legs.push_back(
                {field, subject_kind, subject_id, key_id, before, after});
        };
        for (int32_t local = 0; local < cohort_count; ++local) {
            const int32_t slot = slots[local];
            const int64_t handle = static_cast<int64_t>(_population.handle_for_slot(slot));
            add_leg(FIELD_COHORT_FUNDS, SUBJECT_COHORT, handle, -1,
                    trace_funds_before[local], _population.funds[slot]);
            add_leg(FIELD_COHORT_EPOCH_INCOME, SUBJECT_COHORT, handle, -1,
                    trace_income_before[local], _population.epoch_income[slot]);
            add_leg(FIELD_COHORT_EPOCH_EXPENSE, SUBJECT_COHORT, handle, -1,
                    trace_expense_before[local], _population.epoch_expense[slot]);
            add_leg(FIELD_COHORT_INCOME_EMA, SUBJECT_COHORT, handle, -1,
                    trace_income_ema_before[local], _population.income_ema[slot]);
            add_leg(FIELD_COHORT_SATISFACTION, SUBJECT_COHORT, handle, -1,
                    trace_satisfaction_before[local], _population.needs_satisfaction[slot]);
            add_leg(FIELD_COHORT_WORST_NEED, SUBJECT_COHORT, handle, -1,
                    trace_worst_need_before[local], _population.worst_need_id[slot]);
        }
        for (int32_t good = 0; good < _market.good_count; ++good) {
            const int64_t idx = _market.index(market, good);
            add_leg(FIELD_MARKET_STOCK, SUBJECT_MARKET, market, good,
                    opening_stock[good], _market.stock[idx]);
            add_leg(FIELD_MARKET_PRICE, SUBJECT_MARKET, market, good,
                    trace_price_before[good], _market.price[idx]);
            add_leg(FIELD_MARKET_DEMAND_EMA, SUBJECT_MARKET, market, good,
                    trace_demand_ema_before[good], _market.demand_ema[idx]);
            add_leg(FIELD_MARKET_SHORTAGE, SUBJECT_MARKET, market, good,
                    trace_shortage_before[good], _market.last_shortage_q16[idx]);
        }
    }
    result.price_ms += elapsed_ms(price_start);
    result.processed_cohorts += cohort_count;
    result.processed_rules += result.processed_components;
    finalize_market_result(market, result);
    return true;
}

void NativeEconomyRuntime::finalize_market_result(int32_t market, MarketResult &result) {
    for (int32_t k = _market_cell_offsets[market]; k < _market_cell_offsets[market + 1]; ++k) {
        const int32_t cell = _market_cells[k];
        const CellSummary summary = build_cell_summary(cell);
        stage_cell_summary(cell, summary);
        result.closing_population = saturating_add(result.closing_population, summary.population,
                                                   result.saturation_count);
        result.closing_cohort_funds = saturating_add(result.closing_cohort_funds, summary.funds,
                                                     result.saturation_count);
    }
    for (int32_t good = 0; good < _market.good_count; ++good) {
        result.closing_goods_stock = saturating_add(
            result.closing_goods_stock, _market.stock[_market.index(market, good)],
            result.saturation_count);
    }
}


} // namespace pk

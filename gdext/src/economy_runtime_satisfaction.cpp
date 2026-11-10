#include "economy_cost_probe.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
#include "economy_runtime_variant_helpers.h"
#include "parallel_dispatcher.h"
#include "pk_log.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <limits>
#include <map>
#include <numeric>
#include <tuple>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>

#if defined(_MSC_VER) && defined(_M_X64)
#include <intrin.h>
#endif

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {
using namespace godot;
using namespace variant_helpers;

int32_t popcount_u64(uint64_t value);

int64_t NativeEconomyRuntime::bullion_cell_quota_remaining(
        int32_t cell) const {
    if (cell < 0 || cell >= _cell_count.get()) return 0;
    const uint64_t key = static_cast<uint64_t>(static_cast<uint32_t>(cell));
    const auto it = std::lower_bound(_epoch_bullion_quota_keys.begin(),
        _epoch_bullion_quota_keys.end(), key);
    if (it == _epoch_bullion_quota_keys.end() || *it != key) return 0;
    const size_t index = static_cast<size_t>(it -
        _epoch_bullion_quota_keys.begin());
    return index < _epoch_bullion_quota_remaining.size()
        ? std::max<int64_t>(0, _epoch_bullion_quota_remaining[index]) : 0;
}

int64_t NativeEconomyRuntime::bullion_cell_quota_initial(
        int32_t cell) const {
    if (cell < 0 || cell >= _cell_count.get()) return 0;
    const uint64_t key = static_cast<uint64_t>(static_cast<uint32_t>(cell));
    const auto it = std::lower_bound(_epoch_bullion_quota_keys.begin(),
        _epoch_bullion_quota_keys.end(), key);
    if (it == _epoch_bullion_quota_keys.end() || *it != key) return 0;
    const size_t index = static_cast<size_t>(it -
        _epoch_bullion_quota_keys.begin());
    return index < _epoch_bullion_quota_initial.size()
        ? std::max<int64_t>(0, _epoch_bullion_quota_initial[index]) : 0;
}

int64_t NativeEconomyRuntime::bullion_quota_remaining(
        int32_t cell, int32_t good) const {
    if (good < 0 || good >= market_store().good_count.get() ||
        good >= static_cast<int32_t>(_good_monetary_issue_values.size()) ||
        _good_monetary_issue_values[good] <= 0)
        return 0;
    (void)cell;
    return std::numeric_limits<int64_t>::max();
}

int64_t NativeEconomyRuntime::consume_bullion_quota(
        int32_t cell, int32_t good, int64_t requested, int64_t &sat) {
    if (requested <= 0 || cell < 0 || cell >= _cell_count.get() || good < 0 ||
        good >= market_store().good_count.get()) return 0;
    if (good >= static_cast<int32_t>(_good_monetary_issue_values.size()) ||
        _good_monetary_issue_values[good] <= 0)
        return 0;
    (void)cell;
    (void)sat;
    // Retained API name for old callers; monetary output is no longer capped.
    return requested;
}

int64_t NativeEconomyRuntime::epoch_research_demand_daily(
        int32_t cell, int32_t good) const {
    if (good != _epoch_research_good_id || cell < 0 ||
        cell >= static_cast<int32_t>(_epoch_research_demand_by_cell.size()))
        return 0;
    const int64_t quantity = _epoch_research_demand_by_cell[
        static_cast<size_t>(cell)];
    if (quantity <= 0) return 0;
    const int64_t days = std::max<int64_t>(1, _epoch_days.get());
    return quantity / days + (quantity % days != 0 ? 1 : 0);
}

int64_t NativeEconomyRuntime::epoch_research_demand_daily_for_market(
        int32_t market, int32_t good) const {
    if (good != _epoch_research_good_id || market < 0 ||
        market >= static_cast<int32_t>(_epoch_research_demand_by_market.size()))
        return 0;
    const int64_t quantity = _epoch_research_demand_by_market[
        static_cast<size_t>(market)];
    if (quantity <= 0) return 0;
    const int64_t days = std::max<int64_t>(1, _epoch_days.get());
    return quantity / days + (quantity % days != 0 ? 1 : 0);
}

int32_t NativeEconomyRuntime::set_military_ration_satisfaction(
        const std::vector<int32_t> &cells, const std::vector<int32_t> &q16) {
    const size_t count = std::min(cells.size(), q16.size());
    if (count == 0) return 0;
    // The lane is owned by Military and only meaningful for configured worlds.
    // Size it lazily so an unconfigured runtime is a no-op.
    if (_cell_count.get() > 0 &&
        _military_ration_sat_q16.size() != static_cast<size_t>(_cell_count.get())) {
        _military_ration_sat_q16.assign(static_cast<size_t>(_cell_count.get()),
                                        static_cast<int32_t>(Q16_ONE));
        _military_ration_sat_present.assign(static_cast<size_t>(_cell_count.get()), 0);
    }
    int32_t written = 0;
    for (size_t i = 0; i < count; ++i) {
        const int32_t cell = cells[i];
        if (cell < 0 || cell >= _cell_count.get() ||
            static_cast<size_t>(cell) >= _military_ration_sat_q16.size())
            continue;
        _military_ration_sat_q16[static_cast<size_t>(cell)] = std::clamp<int32_t>(
            q16[i], 0, static_cast<int32_t>(Q16_ONE));
        _military_ration_sat_present[static_cast<size_t>(cell)] = 1;
        ++written;
    }
    return written;
}

bool NativeEconomyRuntime::cell_has_state_service_population(int32_t cell) const {
    if (_state_supplied_need_columns == 0 || cell < 0 || cell >= _cell_count.get())
        return false;
    bool found = false;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        if (found || population_store().population[slot] <= 0) return;
        const uint32_t signature = population_store().signature_id[slot];
        if (signature < _signatures.size() &&
            profession_is_state_service_only(
                _signatures[signature].profession_id))
            found = true;
    });
    return found;
}

bool NativeEconomyRuntime::satisfaction_need_available(const Need &need, int32_t cell) const {
    if (need.base_qty_per_person <= 0 || need.satisfaction_weight_q16 <= 0) return false;
    const int32_t country = cell >= 0 && cell < static_cast<int32_t>(_epoch_cell_country.size())
        ? _epoch_cell_country[cell] : -1;
    for (int32_t v = 0; v < need.variant_count; ++v) {
        const int32_t variant_id = need.variant_begin + v;
        const size_t index = static_cast<size_t>(std::max(0, country)) * _variants.size() + variant_id;
        if (country >= 0 && country < _epoch_country_count && index < _epoch_country_variant_available.size()) {
            if (_epoch_country_variant_available[index] != 0) return true;
            continue;
        }
        const VariantChoice &variant = _variants[variant_id];
        bool available = variant.component_count > 0;
        for (int32_t c = 0; c < variant.component_count && available; ++c)
            available = good_available(cell, _components[variant.component_begin + c].good_id, true);
        if (available) return true;
    }
    return false;
}

uint8_t NativeEconomyRuntime::satisfaction_applicable_mask(int32_t slot) const {
    uint8_t mask = 0xF1; // survival and the four ledger/context dimensions
    const Signature &signature = _signatures[population_store().signature_id[slot]];
    const Plan &plan = _plans[signature.plan_id];
    const int32_t cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
    const EnvironmentSample environment = environment_sample_for_cell(cell);
    for (int32_t n = 0; n < plan.need_count; ++n) {
        const Need &need = _needs[plan.need_begin + n];
        if (sample_environment_curve(need.quantity_env_curve, environment) > 0 &&
                satisfaction_need_available(need, cell) && _ethnicity_need_factor_q16[
                static_cast<size_t>(signature.ethnicity_id) * _need_ids.size() + need.stable_id] > 0)
            mask |= static_cast<uint8_t>(1U << need.satisfaction_tier);
    }
    return mask;
}

std::array<int64_t, NativeEconomyRuntime::SAT_DIM_COUNT>
NativeEconomyRuntime::satisfaction_effective_weights(
        const Signature &signature, uint8_t applicable_mask) const {
    std::array<int64_t, SAT_DIM_COUNT> weights{};
    // Fixed category budgets: absent consumption tiers cannot increase the
    // financial share. Profession weights select priorities inside each group.
    constexpr int32_t begins[] = {0, 4, 6, 7};
    constexpr int32_t ends[] = {4, 6, 7, 8};
    constexpr int64_t budgets[] = {45875, 13107, 3277, 3277};
    for (int32_t group = 0; group < 4; ++group) {
        int64_t total = 0;
        for (int32_t dim = begins[group]; dim < ends[group]; ++dim)
            if ((applicable_mask & (1U << dim)) != 0)
                total += signature.satisfaction_weights_q16[dim];
        if (group == 0 && total <= 0) {
            weights[SAT_DIM_SUBSISTENCE] = budgets[group];
            continue;
        }
        if (total <= 0) continue;
        int64_t prefix = 0, assigned = 0;
        for (int32_t dim = begins[group]; dim < ends[group]; ++dim) {
            if ((applicable_mask & (1U << dim)) == 0) continue;
            prefix += signature.satisfaction_weights_q16[dim];
            const int64_t next = prefix * budgets[group] / total;
            weights[dim] = next - assigned;
            assigned = next;
        }
    }
    return weights;
}

int64_t NativeEconomyRuntime::satisfaction_bias_q16(
        int32_t cell, const Signature &signature) const {
    const int32_t country_slot = cell_country_slot(cell);
    const int32_t profession_id = signature.profession_id;
    const size_t professions = _profession_ids.size();
    const size_t index = static_cast<size_t>(std::max(0, country_slot)) *
        professions + static_cast<size_t>(std::max(0, profession_id));
    if (professions == 0 || country_slot < 0 || profession_id < 0 ||
            static_cast<size_t>(profession_id) >= professions ||
            index >= _epoch_country_profession_satisfaction_bp.size())
        return 0;
    return static_cast<int64_t>(
        _epoch_country_profession_satisfaction_bp[index]) * Q16_ONE / 10000;
}

int64_t NativeEconomyRuntime::satisfaction_ceiling(
        const int64_t *dims, uint8_t applicable_mask, const Signature &signature,
        int32_t &binding_dimension, int64_t &sat) const {
    const auto gate = [&](int32_t dim, int32_t slack) {
        return saturating_add(dims[dim], mul_div_sat(
            Q16_ONE - 1 - dims[dim], slack, Q16_ONE, sat), sat);
    };
    int64_t ceiling = gate(SAT_DIM_SUBSISTENCE, _satisfaction_subsistence_gate_slack_q16);
    binding_dimension = SAT_DIM_SUBSISTENCE;
    const auto tighten = [&](int32_t dim, int64_t candidate) {
        // Strict comparison preserves the stable survival/basic/comfort/luxury
        // priority when two gates have exactly the same fixed-point ceiling.
        if (candidate < ceiling) {
            ceiling = candidate;
            binding_dimension = dim;
        }
    };
    if ((applicable_mask & (1U << SAT_DIM_BASIC)) != 0)
        tighten(SAT_DIM_BASIC, gate(SAT_DIM_BASIC, _satisfaction_basic_gate_slack_q16));
    const auto high_living_gate = [&](int32_t dim, int64_t floor) {
        if ((applicable_mask & (1U << dim)) == 0 ||
                signature.satisfaction_weights_q16[dim] <= 0) return;
        tighten(dim, saturating_add(floor, mul_div_sat(
            Q16_ONE - 1 - floor, dims[dim], Q16_ONE - 1, sat), sat));
    };
    // Missing applicable comfort precludes high satisfaction; missing luxury
    // precludes the very top band. Needs a profession does not value must not
    // become mandatory merely because its plan diagnoses that consumption tier.
    high_living_gate(SAT_DIM_COMFORT, 45875); // 70% + 30% * comfort
    high_living_gate(SAT_DIM_LUXURY, 58982);  // 90% + 10% * luxury
    return ceiling;
}

int32_t NativeEconomyRuntime::consumption_living_standard_level(int32_t slot) const {
    const size_t base = static_cast<size_t>(slot) * SAT_DIM_COUNT;
    const auto dim = [&](int32_t d) { return population_store().satisfaction_dims[base + d]; };
    const uint8_t mask = satisfaction_applicable_mask(slot);
    if (dim(SAT_DIM_SUBSISTENCE) < 32768) return 0;
    if (dim(SAT_DIM_SUBSISTENCE) < 52429) return 1;
    if (dim(SAT_DIM_SUBSISTENCE) < 62259 ||
        ((mask & 2U) && dim(SAT_DIM_BASIC) < 32768)) return 2;
    if (((mask & 2U) && dim(SAT_DIM_BASIC) < 58982) ||
        !(mask & 4U) || dim(SAT_DIM_COMFORT) < 32768) return 3;
    if (dim(SAT_DIM_COMFORT) < 58982) return 4;
    if ((mask & 8U) && dim(SAT_DIM_LUXURY) >= 52429) return 6;
    return 5;
}

int64_t NativeEconomyRuntime::update_cohort_satisfaction(
        int32_t slot, int32_t cell, int64_t subsistence_q16,
        const Signature &signature, const int64_t *tier_weighted_q16,
        const int64_t *tier_weight_q16, int64_t basic_min_fill_q16, int64_t &sat) {
    std::array<int64_t, SAT_DIM_COUNT> dims{};
    uint8_t applicable_mask = 0xF1;
    for (int32_t tier = SAT_DIM_BASIC; tier < SAT_TIER_COUNT; ++tier) {
        const int64_t weight = tier_weight_q16[tier];
        if (weight <= 0) {
            // The plan never asks for this tier, so scoring it would punish a
            // class for needs it does not have. Drop it from the denominator.
            dims[static_cast<size_t>(tier)] = 0; // query exposes this as N/A
        } else {
            applicable_mask |= static_cast<uint8_t>(1U << tier);
            dims[static_cast<size_t>(tier)] = std::clamp<int64_t>(
                tier_weighted_q16[tier] / weight, 0, Q16_ONE - 1);
        }
    }
    if ((applicable_mask & (1U << SAT_DIM_BASIC)) != 0) {
        // Keep aggregate coverage while recognizing a missing basic condition:
        // one unmet need is a shortfall, not proof that all basic life is absent.
        dims[SAT_DIM_BASIC] = (3 * dims[SAT_DIM_BASIC] +
            std::clamp<int64_t>(basic_min_fill_q16, 0, Q16_ONE - 1)) / 4;
    }
    dims[SAT_DIM_SUBSISTENCE] = std::clamp<int64_t>(subsistence_q16, 0,
                                                    Q16_ONE - 1);
    const auto weights = satisfaction_effective_weights(signature, applicable_mask);

    const int64_t population = std::max<int64_t>(1, population_store().population[slot]);
    const int64_t per_capita_income = population_store().income_ema[slot] / population;
    const int64_t per_capita_baseline =
        population_store().income_baseline_ema[slot] / population;
    if (per_capita_baseline <= 0) {
        // No trailing baseline yet (a freshly seeded or freshly emptied cohort).
        // Treat growth as neutral rather than inventing a ratio from zero.
        dims[SAT_DIM_INCOME] = per_capita_income > 0 ? Q16_ONE - 1 : Q16_ONE / 2;
    } else {
        const int64_t growth_q16 = mul_div_sat(
            std::max<int64_t>(0, per_capita_income), Q16_ONE,
            per_capita_baseline, sat);
        dims[SAT_DIM_INCOME] = normalize_band_q16(
            growth_q16, _satisfaction_income_growth_floor_q16,
            _satisfaction_income_growth_ceiling_q16, sat);
    }

    const int64_t daily_living_cost = cell >= 0 &&
            cell < static_cast<int32_t>(_cell_living_cost_per_capita.size())
        ? _cell_living_cost_per_capita[cell] : 0;
    const int64_t monthly_cost = saturating_mul(
        saturating_mul(std::max<int64_t>(0, daily_living_cost), population, sat),
        30, sat);
    // Fixed 30-day reference basket: never shrink this denominator with the
    // household's wealth/price-elastic demand or its actual consumption spend.
    // A missing cost basis is not evidence of unlimited purchasing power.
    const int64_t months_q16 = monthly_cost > 0 ? mul_div_sat(
        std::max<int64_t>(0, population_store().funds[slot]), Q16_ONE,
        monthly_cost, sat) : 0;
    if (monthly_cost <= 0) {
        // Missing valuation is not evidence of a financial buffer.
        dims[SAT_DIM_SAVINGS] = 0;
    } else {
        dims[SAT_DIM_SAVINGS] = normalize_band_q16(
            months_q16, 0, _satisfaction_savings_target_months_q16, sat);
    }

    const int64_t gross_income = saturating_add(
        std::max<int64_t>(0, population_store().epoch_income[slot]),
        std::max<int64_t>(0, population_store().epoch_in_kind_income[slot]), sat);
    const int64_t net_tax = saturating_sub(population_store().epoch_tax_paid[slot],
                                           population_store().epoch_subsidy_received[slot],
                                           sat);
    // X16: this cohort's country + profession decide how much tax burden it tolerates.
    //
    // `_satisfaction_tax_tolerance_q16` is the world-wide default; the per-profession
    // factor scales it (1.15 = "landlords tolerate 15% more burden before the tax
    // dimension starts falling"). Both indices are looked up defensively: a cohort whose
    // cell has no country slot (or whose profession is out of range) simply keeps the
    // default, which is what the fixture-only cells in tests rely on.
    int32_t tax_tolerance_q16 = _satisfaction_tax_tolerance_q16;
    {
        const int32_t country_slot = cell_country_slot(cell);
        const int32_t profession_id = signature.profession_id;
        const size_t professions = _profession_ids.size();
        if (professions > 0 && country_slot >= 0 && profession_id >= 0 &&
            static_cast<size_t>(profession_id) < _profession_ids.size() &&
            static_cast<size_t>(country_slot) * professions +
                    static_cast<size_t>(profession_id) <
                _epoch_country_profession_tax_tolerance_q16.size()) {
            const int32_t factor_q16 = _epoch_country_profession_tax_tolerance_q16[
                static_cast<size_t>(country_slot) * professions +
                static_cast<size_t>(profession_id)];
            tax_tolerance_q16 = static_cast<int32_t>(std::max<int64_t>(1,
                mul_div_sat(tax_tolerance_q16, factor_q16, Q16_ONE, sat)));
        }
    }
    if (net_tax <= 0) {
        dims[SAT_DIM_TAX] = Q16_ONE - 1;
    } else if (gross_income <= 0) {
        // Taxed while earning nothing is the worst possible burden.
        dims[SAT_DIM_TAX] = 0;
    } else {
        const int64_t burden_q16 = mul_div_sat(net_tax, Q16_ONE, gross_income, sat);
        dims[SAT_DIM_TAX] = Q16_ONE - 1 - normalize_band_q16(
            burden_q16, 0, tax_tolerance_q16, sat);
    }

    dims[SAT_DIM_DEVELOPMENT] = cell >= 0 &&
            cell < static_cast<int32_t>(_epoch_cell_development_q16.size())
        ? _epoch_cell_development_q16[cell] : 0;

    int64_t weighted_total = 0;
    int64_t weight_total = 0;
    int64_t worst_shortfall = -1;
    int32_t worst_dimension = static_cast<int32_t>(
        std::numeric_limits<uint8_t>::max());
    for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim) {
        const int64_t weight = weights[static_cast<size_t>(dim)];
        if (weight <= 0) continue;
        const int64_t value = dims[static_cast<size_t>(dim)];
        weighted_total = saturating_add(weighted_total,
                                        saturating_mul(value, weight, sat), sat);
        weight_total = saturating_add(weight_total, weight, sat);
        const int64_t shortfall = saturating_mul(Q16_ONE - 1 - value, weight, sat);
        if (shortfall > worst_shortfall) {
            worst_shortfall = shortfall;
            worst_dimension = dim;
        }
    }
    const int64_t raw_weighted_q16 = weight_total > 0
        ? std::clamp<int64_t>(weighted_total / weight_total, 0, Q16_ONE - 1)
        : Q16_ONE - 1;
    // X16: the per-profession satisfaction bias is applied BEFORE the ceiling, so a
    // positive bias lifts the cohort's own rating but can never buy its way past the
    // needs hierarchy. Applying it after `min(raw, ceiling)` would let a card make a
    // starving city "satisfied", which is the one thing the ceiling exists to prevent.
    const int64_t raw_q16 = std::clamp<int64_t>(
        raw_weighted_q16 + satisfaction_bias_q16(cell, signature),
        0, Q16_ONE - 1);
    // Needs are hierarchical: a cohort that cannot eat may not be rated
    // satisfied because it banked money or lives in a developed city. The
    // ceiling lets the other dimensions lift it only through the configured
    // slack above its subsistence floor.
    int32_t binding_dimension = SAT_DIM_SUBSISTENCE;
    const int64_t ceiling_q16 = satisfaction_ceiling(
        dims.data(), applicable_mask, signature, binding_dimension, sat);
    const int64_t composite_q16 = std::clamp<int64_t>(
        std::min(raw_q16, ceiling_q16), 0, Q16_ONE - 1);
    if (raw_q16 > ceiling_q16) worst_dimension = binding_dimension;

    population_store().composite_satisfaction.write_scalar(slot, static_cast<uint16_t>(composite_q16), market_mutation_sink());
    population_store().worst_dimension_id.write_scalar(slot, static_cast<uint8_t>(worst_dimension), market_mutation_sink());
    const size_t base = static_cast<size_t>(slot) *
        static_cast<size_t>(SAT_DIM_COUNT);
    for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim)
        population_store().satisfaction_dims.write_scalar(base + static_cast<size_t>(dim), static_cast<uint16_t>(dims[static_cast<size_t>(dim)]), market_mutation_sink());
    return composite_q16;
}

int32_t NativeEconomyRuntime::living_standard_level_for(int64_t composite_q16) const {
    // Seven presentation bands over the composite. They are display-only; every
    // gameplay consumer reads composite_satisfaction or a single dimension.
    // Calibrated against the composite, not the old survival figure: a cohort
    // that eats well but owns nothing and lives in a hamlet lands near 0.45, so
    // the bands sit well below the pre-composite thresholds.
    int32_t level = 0;
    while (level < 6 && composite_q16 >= LIVING_STANDARD_THRESHOLDS_Q16[level]) ++level;
    return level;
}

int32_t NativeEconomyRuntime::social_pressure_level_for(
        int64_t composite_q16) const {
    int32_t level = 0;
    while (level < SAT_PRESSURE_LEVEL_COUNT - 1 &&
           composite_q16 >= _satisfaction_pressure_thresholds_q16[level])
        ++level;
    return level;
}

int64_t NativeEconomyRuntime::normalize_band_q16(int64_t value, int64_t floor,
                                                 int64_t ceiling,
                                                 int64_t &sat) const {
    if (ceiling <= floor) return value >= ceiling ? Q16_ONE - 1 : 0;
    if (value <= floor) return 0;
    if (value >= ceiling) return Q16_ONE - 1;
    return std::clamp<int64_t>(
        mul_div_sat(value - floor, Q16_ONE - 1, ceiling - floor, sat), 0,
        Q16_ONE - 1);
}

void NativeEconomyRuntime::refresh_epoch_development() {
    const int32_t country_count = std::max(0, _epoch_country_count);
    _epoch_country_technology_progress_q16.assign(
        static_cast<size_t>(country_count), 0);
    const int64_t technology_total = static_cast<int64_t>(_technology_ids.size());
    for (int32_t country = 0; country < country_count; ++country) {
        if (technology_total <= 0) continue;
        int64_t known = 0;
        const size_t begin = static_cast<size_t>(country) *
            static_cast<size_t>(_epoch_country_technology_words);
        for (int32_t word = 0; word < _epoch_country_technology_words; ++word) {
            const size_t index = begin + static_cast<size_t>(word);
            if (index >= _epoch_country_technologies.size()) break;
            known += popcount_u64(_epoch_country_technologies[index]);
        }
        _epoch_country_technology_progress_q16[country] = static_cast<int32_t>(
            std::clamp<int64_t>(mul_div_sat(std::min(known, technology_total),
                                            Q16_ONE, technology_total,
                                            _saturation_count),
                                0, Q16_ONE));
    }

    const size_t cells = static_cast<size_t>(std::max(0, _cell_count.get()));
    _epoch_cell_development_q16.assign(cells, 0);
    const int64_t weight_total = static_cast<int64_t>(
        _satisfaction_development_weights_q16[0]) +
        _satisfaction_development_weights_q16[1] +
        _satisfaction_development_weights_q16[2];
    if (weight_total <= 0) return;
    const int64_t tier_max = std::max<int64_t>(
        1, static_cast<int64_t>(_prosperity_thresholds.size()) - 1);
    const int64_t variety_target = std::max<int64_t>(
        1, _satisfaction_development_variety_target);
    const bool building_csr_valid =
        _building_cell_offsets.size() == cells + 1;
    for (size_t cell = 0; cell < cells; ++cell) {
        const int64_t tier = cell < _settlements.tier.size()
            ? std::min<int64_t>(_settlements.tier[cell], tier_max) : 0;
        const int64_t tier_q16 = mul_div_sat(tier, Q16_ONE, tier_max,
                                             _saturation_count);
        int64_t technology_q16 = 0;
        if (cell < _epoch_cell_country.size()) {
            const int32_t country = _epoch_cell_country[cell];
            if (country >= 0 && country < country_count)
                technology_q16 = _epoch_country_technology_progress_q16[
                    static_cast<size_t>(country)];
        }
        int64_t variety = 0;
        if (building_csr_valid) {
            // Groups are stored in stable (cell, type, owner) order, so distinct
            // building types are the number of type transitions in the span.
            const int32_t begin = _building_cell_offsets[cell];
            const int32_t end = _building_cell_offsets[cell + 1];
            int32_t previous_type = -1;
            for (int32_t group = begin; group < end; ++group) {
                const int32_t type_id = buildings_store().type_id[group];
                if (type_id == previous_type) continue;
                previous_type = type_id;
                ++variety;
            }
        }
        const int64_t variety_q16 = mul_div_sat(
            std::min(variety, variety_target), Q16_ONE, variety_target,
            _saturation_count);
        const int64_t weighted = saturating_add(saturating_add(
            saturating_mul(tier_q16, _satisfaction_development_weights_q16[0],
                           _saturation_count),
            saturating_mul(technology_q16, _satisfaction_development_weights_q16[1],
                           _saturation_count), _saturation_count),
            saturating_mul(variety_q16, _satisfaction_development_weights_q16[2],
                           _saturation_count), _saturation_count);
        _epoch_cell_development_q16[cell] = static_cast<int32_t>(
            std::clamp<int64_t>(weighted / weight_total, 0, Q16_ONE - 1));
    }
}

int32_t NativeEconomyRuntime::building_neighbor(
        int32_t cell, int32_t direction) const {
    if (cell < 0 || cell >= _cell_count.get() ||
            direction < 0 || direction >= 6) return -1;
    if (_building_neighbors.size() !=
            static_cast<size_t>(_cell_count.get()) * 6) return -1;
    return _building_neighbors[
        static_cast<size_t>(cell) * 6 + static_cast<size_t>(direction)];
}

int32_t NativeEconomyRuntime::city_output_factor_for_test(
        int32_t cell, int32_t good_id) const {
    return city_good_output_factor_q16(cell, good_id);
}

int32_t NativeEconomyRuntime::city_good_output_factor_q16(
        int32_t cell, int32_t good_id) const {
    if (good_id < 0 || good_id >= static_cast<int32_t>(
            _city_output_shared_goods_q16.size()))
        return Q16_ONE;
    const int32_t shared = _city_output_shared_goods_q16[
        static_cast<size_t>(good_id)];
    if (cell < 0 || cell + 1 >= static_cast<int32_t>(
            _city_output_cell_offsets.size()))
        return shared;
    const int32_t begin = _city_output_cell_offsets[
        static_cast<size_t>(cell)];
    const int32_t end = _city_output_cell_offsets[
        static_cast<size_t>(cell + 1)];
    const auto first = _city_output_good_indices.begin() + begin;
    const auto last = _city_output_good_indices.begin() + end;
    const auto found = std::lower_bound(first, last, good_id);
    if (found == last || *found != good_id) return shared;
    return _city_output_factors_q16[static_cast<size_t>(
        std::distance(_city_output_good_indices.begin(), found))];
}

Dictionary NativeEconomyRuntime::explain_cohort_satisfaction(
        int64_t cohort_handle) const {
    Dictionary out;
    int32_t slot = -1;
    if (!_configured ||
        !population_store().valid_handle(static_cast<uint64_t>(cohort_handle), slot)) {
        out["ok"] = false;
        out["reason"] = !_configured ? "economy_not_configured"
                                     : "cohort_handle_invalid";
        return out;
    }
    const int32_t cell = population_store().page_cell[slot / COHORT_PAGE_SIZE];
    const Signature &signature = _signatures[population_store().signature_id[slot]];
    const size_t base = static_cast<size_t>(slot) *
        static_cast<size_t>(SAT_DIM_COUNT);
    PackedInt32Array dim_ids, dim_values, dim_weights, dim_contributions;
    int64_t weighted_total = 0;
    int64_t weight_total = 0;
    int64_t diagnostic_sat = 0;
    const uint8_t applicable_mask = satisfaction_applicable_mask(slot);
    const auto effective_weights = satisfaction_effective_weights(signature, applicable_mask);
    std::array<int64_t, SAT_DIM_COUNT> stored_dims{};
    for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim) {
        const int64_t value = population_store().satisfaction_dims[
            base + static_cast<size_t>(dim)];
        stored_dims[dim] = value;
        const int64_t weight = effective_weights[dim];
        dim_ids.push_back(dim);
        dim_values.push_back((applicable_mask & (1U << dim)) ? static_cast<int32_t>(value) : -1);
        dim_weights.push_back(static_cast<int32_t>(weight));
        // The shortfall each dimension contributes to the composite, which is
        // what makes one of them the worst.
        dim_contributions.push_back(static_cast<int32_t>(std::clamp<int64_t>(
            mul_div_sat(Q16_ONE - 1 - value, weight, Q16_ONE, diagnostic_sat),
            0, Q16_ONE)));
        if (weight <= 0) continue;
        weighted_total = saturating_add(weighted_total,
            saturating_mul(value, weight, diagnostic_sat), diagnostic_sat);
        weight_total = saturating_add(weight_total, weight, diagnostic_sat);
    }
    const int64_t raw_before_bias_q16 = weight_total > 0
        ? std::clamp<int64_t>(weighted_total / weight_total, 0, Q16_ONE - 1)
        : Q16_ONE - 1;
    const int64_t bias_q16 = satisfaction_bias_q16(cell, signature);
    const int64_t raw_q16 = std::clamp<int64_t>(
        raw_before_bias_q16 + bias_q16, 0, Q16_ONE - 1);
    int32_t ceiling_dimension = SAT_DIM_SUBSISTENCE;
    const int64_t ceiling_q16 = satisfaction_ceiling(
        stored_dims.data(), applicable_mask, signature, ceiling_dimension, diagnostic_sat);
    out["ok"] = true;
    out["cohort_handle"] = cohort_handle;
    out["cell_index"] = cell;
    out["signature_id"] = static_cast<int32_t>(population_store().signature_id[slot]);
    out["profession_id"] = signature.profession_id;
    out["population"] = population_store().population[slot];
    out["dim_ids"] = dim_ids;
    out["dim_values_q16"] = dim_values;
    out["dim_weights_q16"] = dim_weights;
    out["dim_contributions_q16"] = dim_contributions;
    out["applicable_mask"] = applicable_mask;
    out["consumption_semantics"] = "realized_over_living_target_basic_completeness_v2";
    out["satisfaction_model_version"] = 2;
    out["basic_average_weight_q16"] = 49152;
    out["basic_worst_weight_q16"] = 16384;
    out["comfort_gate_floor_q16"] = 45875;
    out["luxury_gate_floor_q16"] = 58982;
    out["raw_before_bias_q16"] = raw_before_bias_q16;
    out["bias_q16"] = bias_q16;
    out["raw_q16"] = raw_q16;
    out["ceiling_q16"] = ceiling_q16;
    out["ceiling_dimension_id"] = ceiling_dimension;
    out["ceiling_is_binding"] = raw_q16 > ceiling_q16;
    out["composite_q16"] =
        static_cast<int32_t>(population_store().composite_satisfaction[slot]);
    out["worst_dimension_id"] = population_store().worst_dimension_id[slot] ==
            std::numeric_limits<uint8_t>::max()
        ? -1 : static_cast<int32_t>(population_store().worst_dimension_id[slot]);
    out["worst_need_id"] = population_store().worst_need_id[slot] ==
            std::numeric_limits<uint16_t>::max()
        ? -1 : static_cast<int32_t>(population_store().worst_need_id[slot]);
    out["living_standard_level"] = consumption_living_standard_level(slot);
    out["social_pressure_level"] = social_pressure_level_for(
        population_store().composite_satisfaction[slot]);
    // Raw dimension inputs, so a designer can see why a dimension scored badly
    // rather than only that it did.
    out["income_ema"] = population_store().income_ema[slot];
    out["income_baseline_ema"] = population_store().income_baseline_ema[slot];
    out["funds"] = population_store().funds[slot];
    out["epoch_income"] = population_store().epoch_income[slot];
    out["epoch_in_kind_income"] = population_store().epoch_in_kind_income[slot];
    out["epoch_tax_paid"] = population_store().epoch_tax_paid[slot];
    out["epoch_subsidy_received"] = population_store().epoch_subsidy_received[slot];
    out["living_cost_per_capita"] = cell >= 0 && cell < static_cast<int32_t>(
            _cell_living_cost_per_capita.size())
        ? _cell_living_cost_per_capita[cell] : 0;
    out["settlement_tier"] = cell >= 0 && cell < static_cast<int32_t>(
            _settlements.tier.size())
        ? static_cast<int32_t>(_settlements.tier[cell]) : 0;
    out["development_q16"] = cell >= 0 && cell < static_cast<int32_t>(
            _epoch_cell_development_q16.size())
        ? _epoch_cell_development_q16[cell] : 0;
    out["savings_target_months_q16"] = _satisfaction_savings_target_months_q16;
    const int64_t daily_cost = out["living_cost_per_capita"];
    const int64_t monthly_cost = saturating_mul(saturating_mul(
        std::max<int64_t>(0, daily_cost),
        std::max<int64_t>(1, population_store().population[slot]), diagnostic_sat),
        30, diagnostic_sat);
    out["purchasing_power_basis_valid"] = monthly_cost > 0;
    out["purchasing_power_months_q16"] = monthly_cost > 0 ? mul_div_sat(
        std::max<int64_t>(0, population_store().funds[slot]), Q16_ONE,
        monthly_cost, diagnostic_sat) : 0;
    out["purchasing_power_reference_days"] = 30;
    out["basic_gate_slack_q16"] = _satisfaction_basic_gate_slack_q16;
    out["tax_tolerance_q16"] = _satisfaction_tax_tolerance_q16;
    out["subsistence_gate_slack_q16"] =
        _satisfaction_subsistence_gate_slack_q16;
    return out;
}

} // namespace pk

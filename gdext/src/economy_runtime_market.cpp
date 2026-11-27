#include "economy_runtime.h"
#include "economy_cost_probe.h"
#include "country_api.h"
#include "runtime_switch_registry.h"
#include <algorithm>
#include <array>
#include <chrono>
#include <limits>

namespace pk {

namespace {
using Clock = std::chrono::steady_clock;

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}

int64_t household_threshold_activation_q16(
        int64_t savings_months_q16, int32_t threshold_months_q16,
        int64_t & /*sat*/) {
    constexpr int64_t q16_one = 65536;
    if (threshold_months_q16 <= 0) return q16_one;
    if (savings_months_q16 < threshold_months_q16) return 0;
    const int64_t full = threshold_months_q16 + threshold_months_q16 / 4;
    if (savings_months_q16 >= full) return q16_one;
    return (savings_months_q16 - threshold_months_q16) * q16_one /
        std::max<int64_t>(1, full - threshold_months_q16);
}
} // namespace

int64_t NativeEconomyRuntime::interpolate_household_wealth_lut(
        int64_t wealth_ratio_q16,
        const std::array<int32_t, HOUSEHOLD_WEALTH_ANCHOR_COUNT> &lut,
        int64_t & /*sat*/) {
    const auto &anchors = HOUSEHOLD_WEALTH_ANCHORS_Q16;
    const int64_t ratio = std::clamp<int64_t>(
        wealth_ratio_q16, anchors.front(), anchors.back());
    const auto upper = std::upper_bound(
        anchors.begin(), anchors.end(), ratio);
    if (upper == anchors.begin()) return lut.front();
    if (upper == anchors.end()) return lut.back();
    const size_t hi = static_cast<size_t>(upper - anchors.begin());
    const size_t lo = hi - 1;
    const int64_t x0 = anchors[lo];
    const int64_t x1 = anchors[hi];
    const int64_t y0 = lut[lo];
    const int64_t y1 = lut[hi];
    return y0 + (y1 - y0) * (ratio - x0) / (x1 - x0);
}

int64_t NativeEconomyRuntime::variant_unit_price(int32_t market, int32_t variant_id,
                                                  int64_t &sat) const {
    if (market < 0 || market >= market_store().market_count.get() || variant_id < 0 ||
        variant_id >= static_cast<int32_t>(_variants.size())) return 1;
    const VariantChoice &variant = _variants[variant_id];
    GoodsBill bill;
    for (int32_t c = 0; c < variant.component_count; ++c) {
        const NeedComponent &component = _components[variant.component_begin + c];
        bill.add(effective_household_good_quantity(
                     market, component.good_id, component.qty_per_need, sat),
                 market_store().price[market_store().index(market, component.good_id)], sat);
    }
    return std::max<int64_t>(1, bill.total(sat));
}

void NativeEconomyRuntime::build_demand_basis(
        int32_t market, const EnvironmentSample &sample,
        std::vector<int64_t> &variant_scores, std::vector<int64_t> &variant_prices,
        std::vector<int64_t> &need_score_sums, std::vector<int64_t> &need_composites,
        std::vector<int64_t> &need_environment, int64_t &sat) const {
    EconomyCostProbe cost("demand_basis.compute", _current_day.get(), 1);
    static thread_local bool reference_call = false;
    static const bool disabled = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_PREVIEW_BASIS_DISABLE);
        return value && std::strcmp(value, "1") == 0;
    }();
    static const bool verify = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_MEMO_VERIFY);
        return value && std::strcmp(value, "1") == 0;
    }();
    const bool reuse = !disabled && !reference_call &&
        _preview_need_basis_source.size() == _needs.size();
    static const bool price_basis_disabled = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_VARIANT_PRICE_BASIS_DISABLE);
        return value && std::strcmp(value, "1") == 0;
    }();
    const bool reuse_prices = reuse && !price_basis_disabled;
    thread_local std::vector<VariantPriceBasis> price_basis;
    if (reuse_prices) price_basis.assign(_variants.size(), VariantPriceBasis{});
    uint64_t reused_prices = 0, computed_prices = 0;
    const int64_t initial_sat = sat;
    std::vector<int64_t> need_saturations(reuse ? _needs.size() : 0, 0);
    uint64_t reused = 0;
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
        const int32_t source = reuse ? _preview_need_basis_source[need_index] : need_index;
        if (source < need_index) {
            const Need &original = _needs[source];
            std::copy_n(variant_scores.begin() + original.variant_begin,
                need.variant_count, variant_scores.begin() + need.variant_begin);
            std::copy_n(variant_prices.begin() + original.variant_begin,
                need.variant_count, variant_prices.begin() + need.variant_begin);
            need_score_sums[need_index] = need_score_sums[source];
            need_composites[need_index] = need_composites[source];
            need_environment[need_index] = need_environment[source];
            need_saturations[need_index] = need_saturations[source];
            sat += need_saturations[source];
            ++reused;
            continue;
        }
        const int64_t before = sat;
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
            const int32_t price_source = reuse_prices ? variant.price_basis_source : -1;
            VariantPriceBasis *price_entry = price_source >= 0 &&
                    price_source < static_cast<int32_t>(price_basis.size())
                ? &price_basis[price_source] : nullptr;
            int64_t unit_price = 1, elasticity_factor = 0;
            if (price_entry != nullptr && price_entry->ready) {
                unit_price = price_entry->unit_price;
                elasticity_factor = price_entry->elasticity_factor;
                sat += price_entry->saturations;
                ++reused_prices;
            } else {
                const int64_t price_sat_before = sat;
                unit_price = variant_unit_price(market, variant_id, sat);
                const int64_t price_ratio = mul_div_sat(
                    variant.reference_unit_price, Q16_ONE, unit_price, sat);
                elasticity_factor = pow_q16(std::max<int64_t>(1, price_ratio),
                    variant.price_elasticity_q16, sat);
                if (price_entry != nullptr)
                    *price_entry = {unit_price, elasticity_factor, sat - price_sat_before, true, true};
                ++computed_prices;
            }
            int64_t score = mul_div_sat(
                variant.preference_q16,
                elasticity_factor, Q16_ONE, sat);
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
        if (reuse) need_saturations[need_index] = sat - before;
    }
    EconomyCostProbe::record("demand_basis.needs_reused", _current_day.get(), 0.0, reused);
    EconomyCostProbe::record("demand_basis.price_reused", _current_day.get(), 0.0, reused_prices);
    EconomyCostProbe::record("demand_basis.price_computed", _current_day.get(), 0.0, computed_prices);
    if (reuse && verify) {
        std::vector<int64_t> scores, prices, sums, composites, environment;
        int64_t reference_sat = initial_sat;
        reference_call = true;
        build_demand_basis(market, sample, scores, prices, sums, composites,
            environment, reference_sat);
        reference_call = false;
        if (scores != variant_scores || prices != variant_prices ||
                sums != need_score_sums || composites != need_composites ||
                environment != need_environment || reference_sat != sat) {
            std::fprintf(stderr, "[demand-basis-reuse-mismatch] day=%lld market=%d\n",
                static_cast<long long>(_current_day.get()), market);
            std::abort();
        }
    }
}

int64_t NativeEconomyRuntime::desired_need_units(
        int32_t slot, int32_t need_index, int32_t dt_days,
        int64_t environment_factor_q16, int64_t composite_factor_q16,
        int64_t &sat) const {
    const int64_t funds = slot >= 0 && slot < static_cast<int32_t>(population_store().funds.size())
        ? population_store().funds[slot] : 0;
    return desired_need_units_for_funds(
        slot, need_index, dt_days, environment_factor_q16,
        composite_factor_q16, funds, sat);
}

int64_t NativeEconomyRuntime::desired_need_units_for_funds(
        int32_t slot, int32_t need_index, int32_t dt_days,
        int64_t environment_factor_q16, int64_t composite_factor_q16,
        int64_t funds, int64_t &sat) const {
    if (slot < 0 || slot >= static_cast<int32_t>(population_store().active.size()) ||
        population_store().active[slot] == 0 || need_index < 0 ||
        need_index >= static_cast<int32_t>(_needs.size())) return 0;
    const int64_t population = std::max<int64_t>(0, population_store().population[slot]);
    return desired_need_units_for_actor(
        slot, need_index, dt_days, environment_factor_q16,
        composite_factor_q16, population, funds, sat);
}

int64_t NativeEconomyRuntime::desired_need_units_for_actor(
        int32_t slot, int32_t need_index, int32_t dt_days,
        int64_t environment_factor_q16, int64_t composite_factor_q16,
        int64_t actor_population, int64_t actor_funds, int64_t &sat) const {
    if (slot < 0 || slot >= static_cast<int32_t>(population_store().active.size()) ||
        population_store().active[slot] == 0 || need_index < 0 ||
        need_index >= static_cast<int32_t>(_needs.size())) return 0;
    const uint32_t signature_id = population_store().signature_id[slot];
    if (signature_id >= _signatures.size()) return 0;
    const Signature &signature = _signatures[signature_id];
    const Need &need = _needs[need_index];
    const int64_t population = std::max<int64_t>(0, actor_population);
    if (population <= 0) return 0;
    const int64_t wealth_pc = std::max<int64_t>(0, actor_funds) / population;
    const int64_t wealth_ratio_q16 = mul_div_sat(
        wealth_pc, Q16_ONE, _wealth_reference_per_capita, sat);
    int64_t wealth_factor = interpolate_household_wealth_lut(
        wealth_ratio_q16, need.wealth_lut_q16, sat);
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
    EconomyCostProbe cost("cohort_demand_preview", _current_day.get(), 1);
    const int64_t preview_saturation_before = sat;
    good_per_capita_daily.assign(market_store().good_count.get(), 0);
    if (slot < 0 || slot >= static_cast<int32_t>(population_store().active.size()) ||
        population_store().active[slot] == 0 || market < 0 || market >= market_store().market_count.get())
        return;
    const uint32_t signature_id = population_store().signature_id[slot];
    if (signature_id >= _signatures.size()) return;
    LivingCostMemoState::PreviewBasis local_basis;
    const LivingCostMemoState::PreviewBasis *basis = nullptr;
    auto &memo = living_cost_memo_state();
    const bool country_snapshot_ready = _epoch_active ||
        (memo.owner == this && memo.frozen_country_preview);
    const int32_t country = country_snapshot_ready && market >= 0 &&
            market < static_cast<int32_t>(_epoch_cell_country.size())
        ? _epoch_cell_country[market] : -1;
    const bool memo_active = memo.depth > 0 && memo.owner == this &&
        (price_override == nullptr || memo.frozen_price_overrides);
    // 非空价格只在显式冻结的归因范围复用；指针区分旧价格与本轮最终价格。
    const std::array<int64_t, 10> memo_key{market, country,
        sample.temperature_q16, sample.temperature_30d_q16, sample.moisture_q16,
        sample.plant_available_water_q16, sample.snow_q16, sample.weather_q16,
        sample.ready ? 1 : 0, static_cast<int64_t>(reinterpret_cast<uintptr_t>(price_override))};
    const auto cached = memo.previews.find(memo_key);
    const bool preview_cache_hit = memo_active && cached != memo.previews.end();
    if (preview_cache_hit) {
        basis = &cached->second;
        sat += cached->second.saturations;
        EconomyCostProbe::record("demand_preview.memo_hit", _current_day.get(), 0.0, 1);
    } else {
    EconomyCostProbe basis_cost("demand_preview.basis", _current_day.get(), 1);
    EconomyCostProbe::record("demand_preview.memo_miss", _current_day.get(), 0.0, 1);
    auto &variant_scores = local_basis.scores;
    auto &need_score_sums = local_basis.sums;
    auto &need_composites = local_basis.composites;
    auto &need_environment = local_basis.environment;
    variant_scores.assign(_variants.size(), 0);
    need_score_sums.assign(_needs.size(), 0);
    need_composites.assign(_needs.size(), 0);
    need_environment.assign(_needs.size(), Q16_ONE);
    const int64_t saturation_before = sat;
    std::vector<int64_t> need_saturations(_needs.size(), 0);
    int64_t reused_needs = 0;
    static const bool basis_disabled = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_PREVIEW_BASIS_DISABLE);
        return value && std::strcmp(value, "1") == 0;
    }();
    const bool reuse_basis = memo_active && !basis_disabled;
    static const bool workset_disabled = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_ACTIVE_WORKSET_DISABLE);
        return value && std::strcmp(value, "1") == 0;
    }();
    const bool filter_locked = memo_active && !workset_disabled;
    static const bool price_basis_disabled = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_VARIANT_PRICE_BASIS_DISABLE);
        return value && std::strcmp(value, "1") == 0;
    }();
    const bool reuse_prices = reuse_basis && !price_basis_disabled;
    thread_local std::vector<VariantPriceBasis> price_basis;
    if (reuse_prices) price_basis.assign(_variants.size(), VariantPriceBasis{});
    uint64_t reused_prices = 0, computed_prices = 0;
    uint64_t locked_variants_skipped = 0;
    for (int32_t need_index = 0; need_index < static_cast<int32_t>(_needs.size()); ++need_index) {
        const Need &need = _needs[need_index];
        const int32_t source = reuse_basis &&
                _preview_need_basis_source.size() == _needs.size()
            ? _preview_need_basis_source[need_index] : need_index;
        if (source < need_index) {
            const Need &original = _needs[source];
            std::copy_n(variant_scores.begin() + original.variant_begin,
                need.variant_count, variant_scores.begin() + need.variant_begin);
            need_score_sums[need_index] = need_score_sums[source];
            need_composites[need_index] = need_composites[source];
            need_environment[need_index] = need_environment[source];
            // Replay diagnostic events too, including discarded unavailable
            // variants, exactly as the full computation would have done.
            need_saturations[need_index] = need_saturations[source];
            sat += need_saturations[source];
            ++reused_needs;
            continue;
        }
        const int64_t need_saturation_before = sat;
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
            const bool needs_availability_lookup = country < 0 ||
                availability_index >= _epoch_country_variant_available.size();
            bool availability_checked = false;
            if (filter_locked && variant.preview_price_saturation_free) {
                // EPOCH_BEGIN 的预估发生在 _epoch_active 置位之前；此时沿用
                // 原路径的科技查询，只把它前移，不能让过滤只在周期中途生效。
                if (needs_availability_lookup) {
                    for (int32_t c = 0; c < variant.component_count; ++c)
                        available &= good_available(market,
                            _components[variant.component_begin + c].good_id, true);
                    availability_checked = true;
                }
                if (!available) {
                    ++locked_variants_skipped;
                    continue;
                }
            }
            const int32_t price_source = reuse_prices ? variant.price_basis_source : -1;
            VariantPriceBasis *price_entry = price_source >= 0 &&
                    price_source < static_cast<int32_t>(price_basis.size())
                ? &price_basis[price_source] : nullptr;
            int64_t elasticity_factor = 0;
            if (price_entry != nullptr && price_entry->ready) {
                available = price_entry->available;
                elasticity_factor = price_entry->elasticity_factor;
                sat += price_entry->saturations;
                ++reused_prices;
            } else {
            const int64_t price_sat_before = sat;
            int64_t unit_price = 0;
            for (int32_t c = 0; c < variant.component_count; ++c) {
                const NeedComponent &component = _components[variant.component_begin + c];
                if (!availability_checked && needs_availability_lookup) {
                    available &=
                        good_available(market, component.good_id, true);
                }
                const int32_t price = price_override != nullptr &&
                        component.good_id < static_cast<int32_t>(price_override->size())
                    ? (*price_override)[component.good_id]
                    : market_store().price[market_store().index(market, component.good_id)];
                unit_price = saturating_add(unit_price, mul_div_sat(
                    effective_household_good_quantity(
                        market, component.good_id, component.qty_per_need, sat),
                    price, GOODS_SCALE, sat), sat);
            }
            if (available) {
                unit_price = std::max<int64_t>(1, unit_price);
                const int64_t price_ratio = mul_div_sat(
                    variant.reference_unit_price, Q16_ONE, unit_price, sat);
                elasticity_factor = pow_q16(std::max<int64_t>(1, price_ratio),
                    variant.price_elasticity_q16, sat);
            }
            if (price_entry != nullptr)
                *price_entry = {unit_price, elasticity_factor, sat - price_sat_before, available, true};
            ++computed_prices;
            }
            if (!available) continue;
            int64_t score = mul_div_sat(
                variant.preference_q16,
                elasticity_factor, Q16_ONE, sat);
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
        need_saturations[need_index] = sat - need_saturation_before;
    }
    EconomyCostProbe::record("demand_preview.basis_reused", _current_day.get(), 0.0, reused_needs);
    EconomyCostProbe::record("demand_preview.price_reused", _current_day.get(), 0.0, reused_prices);
    EconomyCostProbe::record("demand_preview.price_computed", _current_day.get(), 0.0, computed_prices);
    EconomyCostProbe::record("demand_preview.locked_variants_skipped",
        _current_day.get(), 0.0, locked_variants_skipped);
    EconomyCostProbe::record("demand_preview.basis_computed", _current_day.get(), 0.0,
        static_cast<int64_t>(_needs.size()) - reused_needs);
    if (memo_active) {
        local_basis.saturations = sat - saturation_before;
        basis = &memo.previews.emplace(memo_key, std::move(local_basis)).first->second;
    } else basis = &local_basis;
    }
    const auto &variant_scores = basis->scores;
    EconomyCostProbe actor_cost("demand_preview.actor", _current_day.get(), 1);
    const auto &need_score_sums = basis->sums;
    const auto &need_composites = basis->composites;
    const auto &need_environment = basis->environment;
    const Plan &plan = _plans[_signatures[signature_id].plan_id];
    const int64_t population = std::max<int64_t>(1, population_store().population[slot]);
    const int64_t wealth_pc = std::max<int64_t>(0, funds_override) / population;
    const int64_t wealth_ratio_q16 = mul_div_sat(
        wealth_pc, Q16_ONE, _wealth_reference_per_capita, sat);
    const int32_t cell = slot >= 0 &&
            slot / COHORT_PAGE_SIZE < static_cast<int32_t>(population_store().page_cell.size())
        ? population_store().page_cell[slot / COHORT_PAGE_SIZE] : -1;
    const int64_t basic_living_cost = cell >= 0 &&
            cell < static_cast<int32_t>(_cell_living_cost_per_capita.size())
        ? _cell_living_cost_per_capita[cell] : 0;
    const int64_t savings_months_q16 = basic_living_cost > 0
        ? mul_div_sat(wealth_pc, Q16_ONE,
            saturating_mul(basic_living_cost, 30, sat), sat) : 0;
    const bool safe_zero_skip =
        population <= (std::numeric_limits<int64_t>::max() >> 20);
    // 一次只读 actor 预估中，家族/人口与消费因子都不变；跨 actor 立即清空。
    thread_local std::vector<int32_t> family_good_factors;
    family_good_factors.assign(_good_ids.size(), -1);
    for (int32_t n = 0; n < plan.need_count; ++n) {
        const int32_t need_index = plan.need_begin + n;
        const Need &need = _needs[need_index];
        const int64_t base_score_sum = need_score_sums[need_index];
        // 所有候选都为零时，原循环只写零后立即 continue；不必再遍历未解锁候选。
        if (memo_active && base_score_sum == 0 && safe_zero_skip) continue;
        std::array<int64_t, MAX_VARIANTS_PER_NEED> cohort_variant_scores{};
        int64_t activation_score_sum = 0;
        int64_t score_sum = 0;
        for (int32_t v = 0; v < need.variant_count; ++v) {
            const int32_t variant_id = need.variant_begin + v;
            const int64_t base_v_score = variant_scores[variant_id];
            if (base_v_score <= 0 && safe_zero_skip) {
                cohort_variant_scores[v] = 0;
                continue;
            }
            int64_t activated = std::max<int64_t>(0, mul_div_sat(
                base_v_score,
                family_variant_preference_factor_q16(slot, variant_id, sat, family_good_factors.data()),
                Q16_ONE, sat));
            activated = mul_div_sat(activated, household_threshold_activation_q16(
                savings_months_q16,
                _variants[variant_id].savings_threshold_months_q16, sat),
                Q16_ONE, sat);
            activated = std::max<int64_t>(0, activated);
            activation_score_sum = saturating_add(
                activation_score_sum, activated, sat);
            const int64_t score = std::max<int64_t>(0, mul_div_sat(
                activated, interpolate_household_wealth_lut(
                    wealth_ratio_q16, _variants[variant_id].wealth_lut_q16, sat),
                Q16_ONE, sat));
            cohort_variant_scores[v] = score;
            score_sum = saturating_add(
                score_sum, score, sat);
        }
        if (score_sum <= 0) continue;
        int64_t desired = desired_need_units_for_funds(
            slot, need_index, 1, need_environment[need_index],
            need_composites[need_index], funds_override, sat);
        if (base_score_sum > 0) {
            desired = mul_div_sat(
                desired, activation_score_sum, base_score_sum, sat);
        }
        int64_t prefix = 0;
        int64_t allocated = 0;
        for (int32_t v = 0; v < need.variant_count; ++v) {
            const int32_t variant_id = need.variant_begin + v;
            prefix = saturating_add(prefix, cohort_variant_scores[v], sat);
            const int64_t next = mul_div_sat(desired, prefix, score_sum, sat);
            const int64_t units = std::max<int64_t>(0, next - allocated);
            allocated = next;
            if (units <= 0) continue;
            const VariantChoice &variant = _variants[variant_id];
            for (int32_t c = 0; c < variant.component_count; ++c) {
                const NeedComponent &component = _components[variant.component_begin + c];
                good_per_capita_daily[component.good_id] = saturating_add(
                    good_per_capita_daily[component.good_id],
                    mul_div_sat(units, effective_household_good_quantity(
                        market, component.good_id, component.qty_per_need, sat),
                        GOODS_SCALE, sat), sat);
            }
        }
    }
    for (int32_t good = 0; good < market_store().good_count.get(); ++good)
        good_per_capita_daily[good] /= population;
    // Validate the complete actor-specific result, including saturation events,
    // against a fresh basis. This diagnostic does not change production cadence.
    static const bool verify_preview_memo = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_MEMO_VERIFY);
        return value && std::strcmp(value, "1") == 0;
    }();
    if (memo_active && verify_preview_memo) {
        const auto *previous_owner = memo.owner;
        memo.owner = nullptr;
        std::vector<int64_t> reference;
        int64_t reference_sat = preview_saturation_before;
        compute_cohort_demand_preview(slot, market, sample, price_override,
            funds_override, reference, reference_sat);
        memo.owner = previous_owner;
        if (reference != good_per_capita_daily || reference_sat != sat) {
            std::fprintf(stderr, "economy_preview_memo_mismatch day=%lld slot=%d market=%d\n",
                static_cast<long long>(_current_day.get()), slot, market);
            std::abort();
        }
    }
}

int64_t NativeEconomyRuntime::survival_required_units(
        int32_t slot, int32_t stable_need_id, int32_t dt_days,
        const EnvironmentSample &sample, int64_t &sat) const {
    if (slot < 0 || slot >= static_cast<int32_t>(population_store().active.size()) ||
        population_store().active[slot] == 0 || stable_need_id < 0 ||
        stable_need_id >= static_cast<int32_t>(_survival_required_need_indices.size())) return 0;
    const int32_t need_index = _survival_required_need_indices[stable_need_id];
    if (need_index < 0 || need_index >= static_cast<int32_t>(_needs.size())) return 0;
    const uint32_t signature_id = population_store().signature_id[slot];
    if (signature_id >= _signatures.size()) return 0;
    const Signature &signature = _signatures[signature_id];
    const Need &need = _needs[need_index];
    const int64_t population = std::max<int64_t>(0, population_store().population[slot]);
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

bool NativeEconomyRuntime::process_market_cell(int32_t market, MarketResult &result,
#include "economy_runtime_market_section_demand_inputs.inc"
#include "economy_runtime_market_section_bundle_quotes.inc"
#include "economy_runtime_market_section_order_settlement.inc"
#include "economy_runtime_market_section_revenue_distribution.inc"
#include "economy_runtime_market_section_consumption_and_livelihood.inc"
#include "economy_runtime_market_section_signals_and_prices.inc"
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
    for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
        result.closing_goods_stock = saturating_add(
            result.closing_goods_stock, market_store().stock[market_store().index(market, good)],
            result.saturation_count);
    }
}


} // namespace pk

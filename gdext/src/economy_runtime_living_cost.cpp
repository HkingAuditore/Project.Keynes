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

void NativeEconomyRuntime::rebuild_labor_signals() {
    LaborMarketStore &next = _labor_signals_rebuild_scratch;
    next.clear(_cell_count.get());
    const size_t old_size = _labor_signals.profession_ids.size();
    next.profession_ids.reserve(old_size);
    next.base_living_cost.reserve(old_size);
    next.role_living_cost.reserve(old_size);
    next.contract_wage_ema.reserve(old_size);
    next.paid_wage_ema.reserve(old_size);
    next.job_days.reserve(old_size);
    next.pay_ratio_q16.reserve(old_size);
    if (_building_labor_signal_stamp.size() != _profession_ids.size()) {
        _building_labor_signal_stamp.assign(_profession_ids.size(), 0);
        _building_labor_signal_stamp_generation = 0;
    }
    if (_labor_signal_cell_dirty.size() != static_cast<size_t>(_cell_count.get())) {
        mark_labor_signal_full_rebuild(
            _labor_signal_force_full ? _labor_signal_full_rebuild_reason.c_str()
                                    : "dirty_mask_resize");
    }
    auto next_stamp = [&]() {
        ++_building_labor_signal_stamp_generation;
        if (_building_labor_signal_stamp_generation == 0) {
            std::fill(_building_labor_signal_stamp.begin(),
                      _building_labor_signal_stamp.end(), 0);
            _building_labor_signal_stamp_generation = 1;
        }
        return _building_labor_signal_stamp_generation;
    };
    const bool old_shape_valid = _labor_signals.cell_offsets.size() ==
        static_cast<size_t>(_cell_count.get() + 1) &&
        static_cast<size_t>(_labor_signals.cell_offsets.back()) <= old_size;
    const bool force_full = _labor_signal_force_full || !old_shape_valid;
    if (force_full && !_labor_signal_force_full)
        _labor_signal_full_rebuild_reason = "shape_invalid";
    int64_t cells_rebuilt = 0;
    for (int32_t cell = 0; cell < _cell_count.get(); ++cell) {
        const bool dirty = force_full ||
            _labor_signal_cell_dirty[static_cast<size_t>(cell)] != 0;
        const int32_t old_begin = old_shape_valid
            ? _labor_signals.cell_offsets[cell] : 0;
        const int32_t old_end = old_shape_valid
            ? _labor_signals.cell_offsets[cell + 1] : 0;
        if (!dirty) {
            for (int32_t signal = old_begin; signal < old_end; ++signal) {
                next.profession_ids.push_back(
                    _labor_signals.profession_ids[signal]);
                next.base_living_cost.push_back(
                    _labor_signals.base_living_cost[signal]);
                next.role_living_cost.push_back(
                    _labor_signals.role_living_cost[signal]);
                next.contract_wage_ema.push_back(
                    _labor_signals.contract_wage_ema[signal]);
                next.paid_wage_ema.push_back(
                    _labor_signals.paid_wage_ema[signal]);
                next.job_days.push_back(_labor_signals.job_days[signal]);
                next.pay_ratio_q16.push_back(
                    _labor_signals.pay_ratio_q16[signal]);
            }
            next.cell_offsets.write_scalar(cell + 1, static_cast<int32_t>(next.profession_ids.size()));
            continue;
        }
        ++cells_rebuilt;
        const uint32_t stamp = next_stamp();
        if (_building_cell_offsets.size() ==
                static_cast<size_t>(_cell_count.get() + 1)) {
            for (int32_t group_index = _building_cell_offsets[cell];
                 group_index < _building_cell_offsets[cell + 1]; ++group_index) {
                const auto group = building_view(static_cast<size_t>(group_index));
                if (group.count <= 0 || group.type_id < 0 ||
                    group.type_id >= static_cast<int32_t>(_building_types.size()))
                    continue;
                const BuildingType &type = _building_types[group.type_id];
                for (int32_t edge = type.labor_signal_begin;
                     edge < type.labor_signal_begin + type.labor_signal_count;
                     ++edge) {
                    _building_labor_signal_stamp[
                        _building_type_labor_signal_professions[edge]] = stamp;
                }
            }
        }
        int32_t old_cursor = old_begin;
        for (int32_t profession = 0;
             profession < static_cast<int32_t>(_profession_ids.size());
             ++profession) {
            if (_building_labor_signal_stamp[profession] != stamp) continue;
            while (old_cursor < old_end &&
                   _labor_signals.profession_ids[old_cursor] < profession)
                ++old_cursor;
            const bool found = old_cursor < old_end &&
                _labor_signals.profession_ids[old_cursor] == profession;
            next.profession_ids.push_back(profession);
            next.base_living_cost.push_back(found
                ? _labor_signals.base_living_cost[old_cursor] : 0);
            next.role_living_cost.push_back(found
                ? _labor_signals.role_living_cost[old_cursor] : 0);
            next.contract_wage_ema.push_back(found
                ? _labor_signals.contract_wage_ema[old_cursor] : 0);
            next.paid_wage_ema.push_back(found
                ? _labor_signals.paid_wage_ema[old_cursor] : 0);
            next.job_days.push_back(found
                ? _labor_signals.job_days[old_cursor] : 0);
            next.pay_ratio_q16.push_back(found
                ? _labor_signals.pay_ratio_q16[old_cursor] : Q16_ONE);
        }
        next.cell_offsets.write_scalar(cell + 1, static_cast<int32_t>(
            next.profession_ids.size()));
    }
    std::swap(_labor_signals, _labor_signals_rebuild_scratch);
    _labor_signal_cells_rebuilt = cells_rebuilt;
    _labor_signal_force_full = false;
    if (!_labor_signal_cell_dirty.empty())
        std::fill(_labor_signal_cell_dirty.begin(),
                  _labor_signal_cell_dirty.end(), 0);
    if (cells_rebuilt == 0)
        _labor_signal_full_rebuild_reason.clear();
}

int32_t NativeEconomyRuntime::labor_signal_index(int32_t cell, int32_t profession) const {
    if (cell < 0 || cell >= _cell_count.get() ||
        _labor_signals.cell_offsets.size() != static_cast<size_t>(_cell_count.get() + 1)) return -1;
    const int32_t begin = _labor_signals.cell_offsets[cell];
    const int32_t end = _labor_signals.cell_offsets[cell + 1];
    const auto first = _labor_signals.profession_ids.begin() + begin;
    const auto last = _labor_signals.profession_ids.begin() + end;
    const auto it = std::lower_bound(first, last, profession);
    return it != last && *it == profession
        ? static_cast<int32_t>(it - _labor_signals.profession_ids.begin()) : -1;
}

NativeEconomyRuntime::LivingCostMemoScope::~LivingCostMemoScope() {
    if (!active) return;
    auto &state = living_cost_memo_state();
    state.quote_enabled = previous_quotes;
    state.frozen_country_preview = previous_frozen_country;
    state.frozen_price_overrides = previous_frozen_prices;
    if (--state.depth == 0) {
        EconomyCostProbe::record("living_cost.memo_hit", runtime._current_day.get(), 0.0, state.hits);
        EconomyCostProbe::record("living_cost.memo_miss", runtime._current_day.get(), 0.0, state.misses);
        state.values.clear();
        state.previews.clear();
        state.retention_targets.clear();
        state.quotes.clear();
        state.owner = nullptr;
    }
}

int64_t NativeEconomyRuntime::living_cost_for_signature(
        int32_t cell, int32_t signature_id, int32_t plan_override, int64_t &sat) const {
    if (cell < 0 || cell >= _cell_count.get() || signature_id < 0 ||
        signature_id >= static_cast<int32_t>(_signatures.size())) return 0;
    const Signature &signature = _signatures[signature_id];
    const int32_t plan_id = plan_override >= 0 ? plan_override : signature.plan_id;
    if (plan_id < 0 || plan_id >= static_cast<int32_t>(_plans.size())) return 0;
    // A memo scope spans only a stage whose prices, environment and frozen
    // quantity modifiers cannot change. Cohort funds/ownership are not inputs.
    const std::array<int32_t, 3> memo_key{cell, plan_id, signature.ethnicity_id};
    auto &memo = living_cost_memo_state();
    const bool memo_active = memo.depth > 0 && memo.owner == this;
    // Cached once: getenv scans the process environment per call and the
    // memo-hit path runs thousands of times per simulated day.
    static const bool verify_living_cost_memo = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_MEMO_VERIFY);
        return value && std::strcmp(value, "1") == 0;
    }();
    if (memo_active) {
        const auto found = memo.values.find(memo_key);
        if (found != memo.values.end()) {
            if (verify_living_cost_memo) {
                const auto *previous_owner = memo.owner;
                memo.owner = nullptr;
                int64_t reference_sat = sat;
                const int64_t reference = living_cost_for_signature(cell, signature_id, plan_override, reference_sat);
                memo.owner = previous_owner;
                if (reference != found->second.first || reference_sat - sat != found->second.second) {
                    std::fprintf(stderr, "[living-cost-memo-mismatch] day=%lld cell=%d\n", static_cast<long long>(_current_day.get()), cell);
                    std::abort();
                }
            }
            sat += found->second.second;
            ++memo.hits;
            return found->second.first;
        }
    }
    const int64_t saturation_before = sat;
    const int32_t market = market_store().cell_to_market[cell];
    const Plan &plan = _plans[plan_id];
    int64_t total = 0;
    for (int32_t n = 0; n < plan.need_count; ++n) {
        const int32_t need_index = plan.need_begin + n;
        const Need &need = _needs[need_index];
        if (need.living_cost_weight_q16 <= 0) continue;
        int64_t score_sum = 0;
        int64_t weighted_price = 0;
        for (int32_t v = 0; v < need.variant_count; ++v) {
            const int32_t variant_id = need.variant_begin + v;
            const VariantChoice &variant = _variants[variant_id];
            const int64_t unit_price = variant_unit_price(market, variant_id, sat);
            const int64_t price_ratio = mul_div_sat(
                variant.reference_unit_price, Q16_ONE, unit_price, sat);
            int64_t score = mul_div_sat(
                variant.preference_q16,
                pow_q16(std::max<int64_t>(1, price_ratio),
                        variant.price_elasticity_q16, sat), Q16_ONE, sat);
            score = mul_div_sat(score,
                sample_environment_curve(variant.preference_env_curve, cell),
                Q16_ONE, sat);
            score = std::max<int64_t>(0, score);
            score_sum = saturating_add(score_sum, score, sat);
            weighted_price = saturating_add(weighted_price,
                saturating_mul(unit_price, score, sat), sat);
        }
        int64_t quantity = saturating_mul(
            need.base_qty_per_person, need.living_cost_weight_q16, sat) >> 16;
        quantity = saturating_mul(quantity,
            sample_environment_curve(need.quantity_env_curve, cell), sat) >> 16;
        const int32_t factor_index = signature.ethnicity_id *
            static_cast<int32_t>(_need_ids.size()) + need.stable_id;
        quantity = saturating_mul(quantity,
            _ethnicity_need_factor_q16[factor_index], sat) >> 16;
        if (quantity <= 0 || score_sum <= 0) continue;
        weighted_price /= score_sum;
        total = saturating_add(total, mul_div_sat(
            quantity, weighted_price, GOODS_SCALE, sat), sat);
    }
    const int64_t result = std::max<int64_t>(0, total);
    if (memo_active) {
        memo.values[memo_key] = {result, sat - saturation_before};
        ++memo.misses;
    }
    return result;
}

void NativeEconomyRuntime::compute_cell_living_costs_from_basis(
        int32_t cell, const std::vector<int64_t> &variant_scores,
        const std::vector<int64_t> &variant_prices,
        const std::vector<int64_t> &need_score_sums,
        const std::vector<int64_t> &need_environment, int64_t &sat) {
    if (cell < 0 || cell >= _cell_count.get()) return;
    // Labor signals only exist where somebody employs somebody, but the
    // per-capita survival-plan cost is needed for every populated cell because
    // the savings satisfaction dimension normalizes against it.
    const bool labor_signals_ready =
        _labor_signals.cell_offsets.size() == static_cast<size_t>(_cell_count.get() + 1) &&
        _labor_signals.cell_offsets[cell] != _labor_signals.cell_offsets[cell + 1];
    const int32_t ethnicity_count = static_cast<int32_t>(_ethnicity_ids.size());
    thread_local std::vector<int64_t> cache;
    thread_local std::vector<int32_t> cached_prices;
    thread_local int64_t cached_catalog_hash = 0;
    thread_local int32_t cached_temperature = std::numeric_limits<int32_t>::min();
    thread_local int32_t cached_moisture = std::numeric_limits<int32_t>::min();
    thread_local int32_t cached_snow = std::numeric_limits<int32_t>::min();
    thread_local int32_t cached_weather = std::numeric_limits<int32_t>::min();
    thread_local uint64_t cached_stock_presence = 0;
    const int32_t market = market_store().cell_to_market[cell];
    const auto price_begin = market_store().price.begin() +
        static_cast<int64_t>(market) * market_store().good_count.get();
    const auto stock_begin = market_store().stock.begin() +
        static_cast<int64_t>(market) * market_store().good_count.get();
    // Each variant is weighted by how much of the cell's need its shelf stock
    // can cover (a quarter day counts as full), quantized to sixteenths: a few
    // units of a scarce good must not price the whole need. The cache hashes
    // the quantized coverage.
    int64_t cell_population = 0;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        cell_population = saturating_add(cell_population,
            std::max<int64_t>(0, population_store().population[slot]), sat);
    });
    constexpr int64_t COVERAGE_STEP_Q16 = Q16_ONE / 16;
    thread_local std::vector<int32_t> variant_coverage_q16;
    variant_coverage_q16.assign(_variants.size(), 0);
    uint64_t stock_presence = 1469598103934665603ULL; // FNV-1a offset basis
    for (const Need &need : _needs) {
        const int64_t daily_need = saturating_mul(
            std::max<int64_t>(1, cell_population),
            std::max<int64_t>(1, need.base_qty_per_person), sat);
        for (int32_t v = 0; v < need.variant_count; ++v) {
            const int32_t variant = need.variant_begin + v;
            const VariantChoice &vc = _variants[variant];
            int64_t purchasable = vc.component_count > 0
                ? std::numeric_limits<int64_t>::max() : 0;
            for (int32_t c = 0; c < vc.component_count; ++c) {
                const NeedComponent &comp = _components[vc.component_begin + c];
                purchasable = std::min(purchasable, mul_div_sat(
                    std::max<int64_t>(0, *(stock_begin + comp.good_id)),
                    GOODS_SCALE, std::max<int64_t>(1, comp.qty_per_need), sat));
            }
            const int64_t coverage = purchasable <= 0 ? 0 :
                std::min<int64_t>(Q16_ONE, mul_div_sat(
                    purchasable, 4 * Q16_ONE, daily_need, sat)) /
                    COVERAGE_STEP_Q16 * COVERAGE_STEP_Q16;
            variant_coverage_q16[static_cast<size_t>(variant)] =
                static_cast<int32_t>(coverage);
            stock_presence = (stock_presence ^
                static_cast<uint64_t>(coverage / COVERAGE_STEP_Q16)) *
                1099511628211ULL;
        }
    }
    const bool same_basis =
        cached_prices.size() == static_cast<size_t>(market_store().good_count.get()) &&
        cached_catalog_hash == _catalog_hash.get() &&
        cached_temperature == _environment_temperature_q16[cell] &&
        cached_moisture == _environment_moisture_q16[cell] &&
        cached_snow == _environment_snow_q16[cell] &&
        cached_weather == _environment_weather_q16[cell] &&
        cached_stock_presence == stock_presence &&
        std::equal(cached_prices.begin(), cached_prices.end(), price_begin);
    if (!same_basis) {
        cached_prices.assign(price_begin, price_begin + market_store().good_count.get());
        cached_catalog_hash = _catalog_hash.get();
        cached_temperature = _environment_temperature_q16[cell];
        cached_moisture = _environment_moisture_q16[cell];
        cached_snow = _environment_snow_q16[cell];
        cached_weather = _environment_weather_q16[cell];
        cached_stock_presence = stock_presence;
        cache.assign(_plans.size() * _ethnicity_ids.size(), -1);
    }
    auto cost = [&](int32_t signature_id, int32_t plan_override) {
        const Signature &signature = _signatures[signature_id];
        const int32_t plan_id = plan_override >= 0 ? plan_override : signature.plan_id;
        const size_t key = static_cast<size_t>(plan_id) * ethnicity_count +
                           signature.ethnicity_id;
        if (cache[key] >= 0) return cache[key];
        int64_t total = 0;
        const Plan &plan = _plans[plan_id];
        for (int32_t n = 0; n < plan.need_count; ++n) {
            const int32_t need_index = plan.need_begin + n;
            const Need &need = _needs[need_index];
            const int64_t score_sum = need_score_sums[need_index];
            if (need.living_cost_weight_q16 <= 0 || score_sum <= 0) continue;
            // Living cost must reflect what a rational consumer would actually
            // pay to satisfy this need, not the average of every listed variant.
            // A variant whose components are out of stock (or a variant that has
            // spiked to a ceiling nobody trades at) is not a real option: the
            // consumer substitutes to a cheaper variant that is in stock (e.g.
            // gathered_plants / game_meat). We therefore aggregate ONLY over
            // in-stock variants, score-weighted for preference among the real
            // options, and clamp the result to a slack multiple of the cheapest
            // in-stock variant so a mid-priced substitute cannot inflate cost.
            int64_t avail_num = 0;      // Sum(price * score) over in-stock variants
            int64_t avail_score = 0;    // Sum(score) over in-stock variants
            int64_t avail_ref_num = 0;  // Sum(reference_price * score) over in-stock
            int64_t min_avail_price = 0; // Cheapest in-stock variant unit price
            int64_t avail_coverage = 0;  // Share of the daily need on the shelf
            for (int32_t v = 0; v < need.variant_count; ++v) {
                const int32_t variant = need.variant_begin + v;
                const VariantChoice &vc = _variants[variant];
                const int64_t coverage = variant_coverage_q16[static_cast<size_t>(variant)];
                if (coverage <= 0) continue;
                avail_coverage = std::min<int64_t>(Q16_ONE,
                    saturating_add(avail_coverage, coverage, sat));
                const int64_t vp = variant_prices[variant];
                const int64_t vs = mul_div_sat(
                    variant_scores[variant], coverage, Q16_ONE, sat);
                avail_num = saturating_add(avail_num,
                    saturating_mul(vp, vs, sat), sat);
                avail_score = saturating_add(avail_score, vs, sat);
                avail_ref_num = saturating_add(avail_ref_num,
                    saturating_mul(vc.reference_unit_price, vs, sat), sat);
                if (min_avail_price == 0 || vp < min_avail_price) {
                    min_avail_price = vp;
                }
            }
            if (avail_score <= 0) {
                // Every variant of this need is (nearly) out of stock: the consumer cannot
                // spend anything on it, so it contributes nothing to living cost.
                // (Wage floors should only cover goods people can actually buy;
                // an unpurchasable need does not create a real cost of living, and
                // its ghost/ceiling listing prices must not pollute the aggregate.
                // Genuine survival pressure comes from staple_food/protein having
                // no cheap in-stock substitute, which those needs handle directly.)
                continue;
            }
            int64_t weighted_price = avail_num / avail_score;
            // Clamp to 1.5x the cheapest in-stock option: consumers will not
            // pay far above the cheapest viable substitute they can actually buy.
            const int64_t price_cap = saturating_mul(
                min_avail_price, 98304 /* 1.5 in Q16 */, sat) >> 16;
            if (price_cap > 0 && weighted_price > price_cap) {
                weighted_price = price_cap;
            }
            // Essentialness cap: even if every in-stock variant is expensive, a
            // NON-essential need must not manufacture society-wide inflation. Only
            // the essential portion of a price rise feeds living cost (and thus the
            // wage floor). Essentialness is read from the need's demand floor
            // (price_quantity_floor_q16): a high floor means demand stays high even
            // when prices soar (a true necessity like staple grain, which should
            // track market price fully), while a zero floor means demand collapses
            // to nothing when prices rise (a discretionary need like protein/produce
            // with substitutes -- consumers simply stop buying, so it must not lift
            // the cost of living). floor is in [0, 0.5]; scale by 2 so a 0.5 floor
            // maps to full pass-through and 0 maps to no pass-through.
            // A free "buffer band" up to 1.5x the reference price passes through
            // unclamped: a mild price rise is normal and should be reflected even
            // for discretionary needs ("a little more expensive is fine"). Only
            // the portion ABOVE that band is throttled by essentialness, so a
            // runaway spike ("it soared, so I just stop buying") cannot inflate
            // the cost of living for a non-essential need.
            const int64_t ref_price = avail_ref_num / avail_score;
            const int64_t buffer_threshold =
                saturating_mul(ref_price, 98304 /* 1.5 in Q16 */, sat) >> 16;
            if (weighted_price > buffer_threshold && buffer_threshold > 0) {
                int64_t essential_q16 = saturating_mul(
                    need.price_quantity_floor_q16, 2, sat);
                if (essential_q16 > Q16_ONE) essential_q16 = Q16_ONE;
                if (essential_q16 < 0) essential_q16 = 0;
                const int64_t excess = weighted_price - buffer_threshold;
                const int64_t allowed_excess =
                    saturating_mul(excess, essential_q16, sat) >> 16;
                weighted_price = saturating_add(buffer_threshold, allowed_excess, sat);
            }
            int64_t quantity = saturating_mul(
                need.base_qty_per_person, need.living_cost_weight_q16, sat) >> 16;
            quantity = saturating_mul(
                quantity, need_environment[need_index], sat) >> 16;
            const int32_t factor = signature.ethnicity_id *
                static_cast<int32_t>(_need_ids.size()) + need.stable_id;
            quantity = saturating_mul(
                quantity, _ethnicity_need_factor_q16[factor], sat) >> 16;
            quantity = mul_div_sat(quantity, avail_coverage, Q16_ONE, sat);
            total = saturating_add(total, mul_div_sat(
                quantity, weighted_price, GOODS_SCALE, sat), sat);
        }
        cache[key] = std::max<int64_t>(0, total);
        return cache[key];
    };
    int64_t population_total = 0;
    int64_t general_weighted = 0;
    population_store().for_each_in_cell(cell, [&](int32_t slot) {
        const int64_t population = std::max<int64_t>(0, population_store().population[slot]);
        if (population <= 0) return;
        const int32_t signature = static_cast<int32_t>(population_store().signature_id[slot]);
        population_total = saturating_add(population_total, population, sat);
        general_weighted = saturating_add(general_weighted, saturating_mul(
            cost(signature, _living_cost_base_plan_id), population, sat), sat);
    });
    const int64_t general = population_total > 0
        ? general_weighted / population_total : 0;
    if (cell < static_cast<int32_t>(_cell_living_cost_per_capita.size()))
        _cell_living_cost_per_capita[cell] = general;
    if (!labor_signals_ready) return;
    for (int32_t signal = _labor_signals.cell_offsets[cell];
         signal < _labor_signals.cell_offsets[cell + 1]; ++signal) {
        const int32_t profession = _labor_signals.profession_ids[signal];
        int64_t employed = 0;
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            const int32_t signature = static_cast<int32_t>(population_store().signature_id[slot]);
            if (_signatures[signature].profession_id == profession)
                employed = saturating_add(employed,
                    std::max<int64_t>(0, population_store().employee_employed[slot]), sat);
        });
        int64_t weight_total = 0;
        int64_t weighted = 0;
        population_store().for_each_in_cell(cell, [&](int32_t slot) {
            const int32_t signature = static_cast<int32_t>(population_store().signature_id[slot]);
            if (_signatures[signature].profession_id != profession) return;
            const int64_t weight = employed > 0
                ? std::max<int64_t>(0, population_store().employee_employed[slot])
                : std::max<int64_t>(0, population_store().population[slot]);
            if (weight <= 0) return;
            weight_total = saturating_add(weight_total, weight, sat);
            weighted = saturating_add(weighted,
                saturating_mul(cost(signature, -1), weight, sat), sat);
        });
        _labor_signals.base_living_cost.write_scalar(signal, general, market_mutation_sink());
        _labor_signals.role_living_cost.write_scalar(signal, weight_total > 0 ? weighted / weight_total : 0, market_mutation_sink());
    }
}

} // namespace pk

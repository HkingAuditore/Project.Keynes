// NativeEconomyRuntime::reconcile_family_branch_effects, extracted from economy_runtime.cpp; body is token-preserved.
#include "economy_cost_probe.h"
#include "economy_effect_forward.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
#include "economy_runtime_internal_external_types.inc"
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


namespace {
bool reconcile_trigger_branch_binding(TriggerRuntime *runtime,
                                      const std::string &key,
                                      uint64_t branch_handle,
                                      int32_t cell,
                                      int32_t reward_target,
                                      bool enabled) {
    if (runtime == nullptr || key.empty()) return false;
    Dictionary batch;
    PackedStringArray keys;
    PackedInt64Array branches;
    PackedInt32Array cells;
    PackedInt32Array rewards;
    PackedByteArray states;
    keys.push_back(key.c_str());
    branches.push_back(static_cast<int64_t>(branch_handle));
    cells.push_back(cell);
    rewards.push_back(reward_target);
    states.push_back(enabled ? 1 : 0);
    batch["trigger_keys"] = keys;
    batch["branch_handles"] = branches;
    batch["cells"] = cells;
    batch["reward_targets"] = rewards;
    batch["enabled"] = states;
    const Dictionary result = runtime->reconcile_branch_bindings(batch);
    return static_cast<bool>(result.get("ok", false));
}

int32_t modifier_factor_q16(double factor) {
    if (!std::isfinite(factor) || factor <= 0.0) return 0;
    const double scaled = std::round(factor *
        static_cast<double>(NativeEconomyRuntime::Q16_ONE));
    return static_cast<int32_t>(std::clamp(
        scaled, 0.0, static_cast<double>(std::numeric_limits<int32_t>::max())));
}
} // namespace

namespace {

using Clock = std::chrono::steady_clock;

// effect_pod_upsert / effect_pod_metric / effect_pod_retire now live in
// economy_effect_forward.h: the family write points are split across
// economy_runtime.cpp and economy_runtime_family_buff.cpp, and both translation
// units have to funnel through the same routing decision.

constexpr int64_t price_adjustment_reference(
        int64_t current_price, int64_t adjustment_anchor_price,
        int64_t period_change_q16) {
    return period_change_q16 < 0
        ? std::max<int64_t>(NativeEconomyRuntime::PRICE_NUMERIC_GUARD_MIN,
                            current_price)
        : adjustment_anchor_price;
}

static_assert(price_adjustment_reference(100, 1000, -1) == 100);
static_assert(price_adjustment_reference(100, 1000, 1) == 1000);

double elapsed_ms(const Clock::time_point &start) {
    return std::chrono::duration<double, std::milli>(Clock::now() - start).count();
}


} // namespace

// ─── PopulationStore ───────────────────────────────────────────────────

// PopulationStore implementation moved to economy_runtime_storage.cpp.

// PopulationStore allocation and lookup implementation moved to
// economy_runtime_storage.cpp.

// PopulationStore::allocate_slot implementation moved to
// economy_runtime_storage.cpp.

// PopulationStore handle/release implementation moved to
// economy_runtime_storage.cpp.



NativeEconomyRuntime::OwnerOpportunityQuote
NativeEconomyRuntime::owner_opportunity_quote_uncached(
        BuildingGroupConstRef group, int64_t owner_fillability_q16,
        int64_t employee_fillability_q16, int64_t &sat) const {
    EconomyCostProbe cost("owner_opportunity_quote", _current_day.get(), 1);
    OwnerOpportunityQuote quote;
    if (group.type_id < 0 || group.type_id >=
            static_cast<int32_t>(_building_types.size()) || group.count <= 0 ||
            !building_available(group.cell, group.type_id, true)) return quote;
    const BuildingType &type = _building_types[group.type_id];
    // Suspended non-survival lots stay invisible to opportunity ranking.
    // Survival-food shells need a counterfactual quote so empty hunting camps
    // can attract transfers after SUSPENDED_LOSS; investment still rejects
    // suspended capacity separately.
    if (group.operating_state == 1) {
        bool survival_food = false;
        for (int32_t i = 0; i < type.output_count; ++i) {
            const int32_t good = _building_outputs[type.output_begin + i].good_id;
            if (good >= 0 &&
                good < static_cast<int32_t>(_survival_food_good_mask.size()) &&
                _survival_food_good_mask[good] != 0) {
                survival_food = true;
                break;
            }
        }
        if (!survival_food) return quote;
    }
    const int32_t market = group.cell >= 0 && group.cell < _cell_count.get()
        ? market_store().cell_to_market[group.cell] : -1;
    if (market < 0 || market >= market_store().market_count.get()) return quote;
    const int32_t owner_slot = find_cohort_slot(
        group.cell, group.owner_signature_id);
    const bool has_owner_cohort = owner_slot >= 0 && owner_slot <
        static_cast<int32_t>(population_store().population.size()) &&
        population_store().population[owner_slot] > 0;
    // A vacant knapping workshop with no artisan cohort is the canonical
    // derived-demand isolation case.  Shadow flint pressure may rank the
    // upstream quarry, but it must not manufacture a tool-maker owner slot.
    // Keep this gate narrow: an existing artisan cohort can still operate the
    // workshop from a real upstream shortage, and other building types retain
    // their normal counterfactual owner quote.
    if (!has_owner_cohort && group.type_id >= 0 &&
        group.type_id < static_cast<int32_t>(_building_type_ids.size()) &&
        _building_type_ids[group.type_id] == "knapping_workshop") {
        bool real_output_demand = false;
        bool output_stock_available = false;
        for (int32_t i = 0; i < type.output_count; ++i) {
            const int32_t good = _building_outputs[type.output_begin + i].good_id;
            const int32_t signal = market_signal_index(group.cell, good);
            if (signal >= 0) {
                const int32_t lane = market_store().index(market, good);
                const int64_t household = lane >= 0 && lane <
                        static_cast<int32_t>(market_store().demand_ema.size())
                    ? market_store().demand_ema[lane] : 0;
                const int64_t business = signal < static_cast<int32_t>(
                        _market_signals.business_demand_ema.size())
                    ? _market_signals.business_demand_ema[signal] : 0;
                const int64_t withdrawal = signal < static_cast<int32_t>(
                        _market_signals.realized_withdrawal_ema.size())
                    ? _market_signals.realized_withdrawal_ema[signal] : 0;
                if (household > 0 || business > 0 || withdrawal > 0 ||
                    epoch_procurement_demand_daily(group.cell, good) > 0)
                    real_output_demand = true;
            }
            const int32_t lane = market_store().index(market, good);
            if (lane >= 0 && lane < static_cast<int32_t>(market_store().stock.size()) &&
                market_store().stock[lane] > 0)
                output_stock_available = true;
        }
        // Shadow demand is never enough to create a cold-start owner.  A
        // stocked output lane, however, is a real price/stock opportunity and
        // may establish the first owner even when the EMA is still cold.
        if (!real_output_demand && !output_stock_available) return quote;
    }
    // Workforce is a separate outer scale. Natural capacity below is formed
    // independently, so owner attendance is multiplied exactly once instead
    // of competing with climate/resource factors through a global min().
    static const bool quote_trace = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_OWNER_QUOTE_TRACE);
        return value && std::strcmp(value, "1") == 0;
    }();
    // Section timing uses a thread-local accumulator: a per-call probe record
    // (mutex + CSV row) would cost more than the sections it measures and
    // would be booked outside the measured spans, hiding ~30% of the quote.
    struct QuoteSectionTrace {
        int64_t day = -9223372036854775807LL;
        double setup_ms = 0.0;
        double setup_res_ms = 0.0;
        double setup_living_ms = 0.0;
        uint64_t setup_living_hits = 0;
        uint64_t setup_living_misses = 0;
        double clamp_headroom_ms = 0.0;
        double setup_wages_ms = 0.0;
        double setup_maint_ms = 0.0;
        double setup_env_ms = 0.0;
        double input_scan_ms = 0.0;
        double funds_clamp_ms = 0.0;
        double funds_clamp_bare_ms = 0.0;
        double finalize_tooled_ms = 0.0;
        double finalize_bare_ms = 0.0;
        double fin_pre_ms = 0.0;
        double fin_natural_ms = 0.0;
        double fin_input_cost_ms = 0.0;
        double fin_outputs_ms = 0.0;
        double fin_income_ms = 0.0;
        double fin_proj_ms = 0.0;
        uint64_t calls = 0;
    };
    thread_local QuoteSectionTrace quote_sections;
    const auto add_quote_section = [](double &slot,
                                      const Clock::time_point &started) {
        slot += elapsed_ms(started);
    };
    const auto reset_quote_sections = [](int64_t day) {
        quote_sections = QuoteSectionTrace{};
        quote_sections.day = day;
    };
    if (quote_trace && quote_sections.day != _current_day.get()) {
        const int64_t trace_day = quote_sections.day;
        if (quote_sections.calls > 0) {
            EconomyCostProbe::record("owner_quote.tl_setup", trace_day,
                                     quote_sections.setup_ms,
                                     quote_sections.calls);
            EconomyCostProbe::record("owner_quote.tl_setup_res", trace_day,
                                     quote_sections.setup_res_ms);
            EconomyCostProbe::record("owner_quote.tl_setup_living", trace_day,
                                     quote_sections.setup_living_ms);
            EconomyCostProbe::record("owner_quote.tl_setup_living_hits", trace_day,
                                     0.0, quote_sections.setup_living_hits);
            EconomyCostProbe::record("owner_quote.tl_setup_living_misses", trace_day,
                                     0.0, quote_sections.setup_living_misses);
            EconomyCostProbe::record("owner_quote.tl_clamp_headroom", trace_day,
                                     quote_sections.clamp_headroom_ms);
            EconomyCostProbe::record("owner_quote.tl_setup_wages", trace_day,
                                     quote_sections.setup_wages_ms);
            EconomyCostProbe::record("owner_quote.tl_setup_maint", trace_day,
                                     quote_sections.setup_maint_ms);
            EconomyCostProbe::record("owner_quote.tl_setup_env", trace_day,
                                     quote_sections.setup_env_ms);
            EconomyCostProbe::record("owner_quote.tl_input_scan", trace_day,
                                     quote_sections.input_scan_ms);
            EconomyCostProbe::record("owner_quote.tl_funds_clamp", trace_day,
                                     quote_sections.funds_clamp_ms);
            EconomyCostProbe::record("owner_quote.tl_funds_clamp_bare", trace_day,
                                     quote_sections.funds_clamp_bare_ms);
            EconomyCostProbe::record("owner_quote.tl_finalize_tooled", trace_day,
                                     quote_sections.finalize_tooled_ms);
            EconomyCostProbe::record("owner_quote.tl_finalize_bare", trace_day,
                                     quote_sections.finalize_bare_ms);
            EconomyCostProbe::record("owner_quote.tl_fin_pre", trace_day,
                                     quote_sections.fin_pre_ms);
            EconomyCostProbe::record("owner_quote.tl_fin_natural", trace_day,
                                     quote_sections.fin_natural_ms);
            EconomyCostProbe::record("owner_quote.tl_fin_input_cost", trace_day,
                                     quote_sections.fin_input_cost_ms);
            EconomyCostProbe::record("owner_quote.tl_fin_outputs", trace_day,
                                     quote_sections.fin_outputs_ms);
            EconomyCostProbe::record("owner_quote.tl_fin_income", trace_day,
                                     quote_sections.fin_income_ms);
            EconomyCostProbe::record("owner_quote.tl_fin_proj", trace_day,
                                     quote_sections.fin_proj_ms);
        }
        reset_quote_sections(_current_day.get());
    }
    const auto quote_setup_started = Clock::now();
    const int64_t owner_scale_q16 = std::clamp<int64_t>(
        owner_fillability_q16, 0, Q16_ONE);
    const int64_t employee_scale_q16 = type.employee_count > 0
        ? std::clamp<int64_t>(employee_fillability_q16, 0, Q16_ONE)
        : Q16_ONE;
    const int64_t workforce_scale_q16 = std::min(
        owner_scale_q16, employee_scale_q16);
    int64_t natural_scale_q16 = Q16_ONE;
    int64_t resource_factor_q16 = Q16_ONE;
    // A zero climate capacity is the uninitialized value before the first
    // production observation, not evidence that the counterfactual lot is
    // climatically impossible. Apply the measured capacity only after the
    // group has an observed period; otherwise vacant owner openings can never
    // attract their first owner.
    if (group.last_observed_capacity_days_q16 > 0) {
        quote.climate_factor_q16 = std::clamp<int64_t>(
            group.last_climate_capacity_q16, 0, Q16_ONE);
        natural_scale_q16 = mul_div_sat(natural_scale_q16,
            quote.climate_factor_q16, Q16_ONE, sat);
    }
    // The previous plan may be zero because this established group is vacant.
    // It is not an executable constraint for a counterfactual quote; otherwise
    // vacancy would feed back into a permanent zero-income quote.
    // Resource capacity is part of the opportunity, even when the installed
    // group is currently empty. This keeps a quote executable rather than a
    // nameplate-only accounting value.
    const auto setup_res_started = Clock::now();
    const int64_t building_days = saturating_mul(
        group.count, std::max<int64_t>(1, _epoch_days.get()), sat);
    for (int32_t i = 0; i < type.resource_count; ++i) {
        const ResourceAmount &resource = _building_resources[type.resource_begin + i];
        const int64_t base = resource.mode == 1
            ? saturating_mul(group.count, resource.quantity, sat)
            : saturating_mul(building_days, resource.quantity, sat);
        if (base <= 0) continue;
        const int64_t effective = effective_resource_use_quantity(
            group.cell, resource.resource_id, base, sat);
        if (effective <= 0) {
            resource_factor_q16 = 0;
            break;
        }
        const int64_t available = available_resource_amount(resource, group.cell);
        int64_t availability_factor_q16 = std::clamp<int64_t>(mul_div_sat(
            available, Q16_ONE, effective, sat), 0, Q16_ONE);
        if (resource.mode == 0 &&
            resource_is_renewable(resource.resource_id)) {
            const int64_t density_q16 = std::clamp<int64_t>(
                resource_stock_density_q16(resource.resource_id, group.cell),
                0, Q16_ONE);
            availability_factor_q16 = mul_div_sat(availability_factor_q16,
                density_q16, Q16_ONE, sat);
        }
        resource_factor_q16 = mul_div_sat(resource_factor_q16,
            availability_factor_q16, Q16_ONE, sat);
    }
    if (quote_trace)
        add_quote_section(quote_sections.setup_res_ms, setup_res_started);
    quote.owner_run_q16 = owner_scale_q16;
    quote.climate_factor_q16 = group.last_observed_capacity_days_q16 > 0
        ? std::clamp<int64_t>(group.last_climate_capacity_q16, 0, Q16_ONE)
        : Q16_ONE;
    quote.resource_factor_q16 = resource_factor_q16;
    quote.natural_capacity_q16 = mul_div_sat(
        quote.climate_factor_q16, resource_factor_q16, Q16_ONE, sat);
    natural_scale_q16 = quote.natural_capacity_q16;
    int64_t scale = mul_div_sat(workforce_scale_q16,
        natural_scale_q16, Q16_ONE, sat);
    quote.prospective_scale_q16 = scale;
    quote.executable_capacity_q16 = scale;
    if (scale <= 0) return quote;

    int64_t owner_slots = saturating_mul(group.count,
        type.owner_slots_per_building, sat);
    owner_slots = std::max<int64_t>(1, owner_slots);
    const auto setup_living_started = Clock::now();
    uint64_t living_hits_before = 0;
    uint64_t living_misses_before = 0;
    if (quote_trace) {
        const auto &living_memo = living_cost_memo_state();
        living_hits_before = living_memo.hits;
        living_misses_before = living_memo.misses;
    }
    quote.owner_living_cost = saturating_mul(
        living_cost_for_signature(group.cell, group.owner_signature_id,
            _living_cost_base_plan_id, sat), owner_slots, sat);
    if (quote_trace) {
        const auto &living_memo = living_cost_memo_state();
        quote_sections.setup_living_hits +=
            living_memo.hits - living_hits_before;
        quote_sections.setup_living_misses +=
            living_memo.misses - living_misses_before;
    }
    if (quote_trace)
        add_quote_section(quote_sections.setup_living_ms, setup_living_started);
    const auto setup_wages_started = Clock::now();
    int64_t wages_at_full_scale = 0;
    for (int32_t r = 0; r < type.employee_count; ++r) {
        const JobRole &role = _building_employee_roles[type.employee_begin + r];
        const int32_t ri = group.employee_fill_begin + r;
        const int32_t signal = labor_signal_index(group.cell, role.profession_id);
        const int64_t living_floor = signal >= 0
            ? std::max(_labor_signals.base_living_cost[signal],
                _labor_signals.role_living_cost[signal]) : 0;
        const int64_t market_quote = signal >= 0 && signal <
                static_cast<int32_t>(_labor_signals.contract_wage_ema.size())
            ? std::max(_labor_signals.contract_wage_ema[signal],
                _labor_signals.paid_wage_ema[signal]) : 0;
        const int64_t wage = ri >= 0 && ri < static_cast<int32_t>(
                _building_role_contract_wage.size())
            ? std::max<int64_t>(0, _building_role_contract_wage[ri]) : 0;
        const int64_t effective_wage = std::max({living_floor, market_quote, wage});
        wages_at_full_scale = saturating_add(wages_at_full_scale, saturating_mul(
            group.count, saturating_mul(role.slots_per_building, effective_wage, sat), sat), sat);
    }
    if (quote_trace)
        add_quote_section(quote_sections.setup_wages_ms, setup_wages_started);
    const auto setup_maint_started = Clock::now();
    int64_t maintenance_at_full_scale = daily_maintenance_cost_for_type(
        group.cell, type, sat);
    if (maintenance_at_full_scale == std::numeric_limits<int64_t>::max())
        maintenance_at_full_scale = 0;
    maintenance_at_full_scale = mul_div_sat(maintenance_at_full_scale,
        group.count, 1, sat);

    if (quote_trace)
        add_quote_section(quote_sections.setup_maint_ms, setup_maint_started);
    const auto setup_env_started = Clock::now();
    const int32_t owner_plan_id = group.owner_signature_id >= 0 &&
            group.owner_signature_id < static_cast<int32_t>(_signatures.size())
        ? _signatures[group.owner_signature_id].plan_id : -1;
    const EnvironmentSample owner_environment = environment_sample_for_cell(group.cell);
    if (quote_trace)
        add_quote_section(quote_sections.setup_env_ms, setup_env_started);
    // Quote the quantity this owner cohort could consume from its own output.
    // This is deliberately plan-based, so non-food workshops receive the same
    // in-kind treatment as farms when their goods are in the owner's basket.
    auto output_retention_target = [&](int32_t output_good) -> int64_t {
        if (output_good < 0 || output_good >= market_store().good_count.get() || owner_plan_id < 0 ||
            owner_plan_id >= static_cast<int32_t>(_plans.size())) return 0;
        auto &memo = living_cost_memo_state();
        static const bool retention_disabled = [] {
            const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_RETENTION_MEMO_DISABLE);
            return value && std::strcmp(value, "1") == 0;
        }();
        const bool reuse_retention = !retention_disabled && memo.owner == this && memo.depth > 0;
        const std::array<int64_t, 4> key{group.cell, owner_plan_id, owner_slots, output_good};
        const auto compute = [&](int64_t &sat) {
        const Plan &plan = _plans[owner_plan_id];
        int64_t target = 0;
        for (int32_t n = 0; n < plan.need_count; ++n) {
            const int32_t need_index = plan.need_begin + n;
            if (need_index < 0 || need_index >= static_cast<int32_t>(_needs.size())) continue;
            const Need &need = _needs[need_index];
            if (need.base_qty_per_person <= 0) continue;
            const int64_t env_q16 = sample_environment_curve(
                need.quantity_env_curve, owner_environment);
            int64_t desired = 0;
            // Keep the quote side-effect free and robust for partially
            // migrated catalogs: use the frozen per-person basket basis here
            // instead of requiring a live cohort demand preview.
            desired = mul_div_sat(saturating_mul(owner_slots,
                need.base_qty_per_person, sat), env_q16, Q16_ONE, sat);
            if (desired <= 0) continue;
            int64_t score_sum = 0;
            int64_t matching_score = 0;
            for (int32_t v = 0; v < need.variant_count; ++v) {
                const int32_t variant_id = need.variant_begin + v;
                if (variant_id < 0 || variant_id >= static_cast<int32_t>(_variants.size())) continue;
                const VariantChoice &variant = _variants[variant_id];
                int64_t score = mul_div_sat(variant.preference_q16,
                    sample_environment_curve(variant.preference_env_curve,
                        owner_environment), Q16_ONE, sat);
                score = std::max<int64_t>(1, score);
                score_sum = saturating_add(score_sum, score, sat);
                for (int32_t c = 0; c < variant.component_count; ++c) {
                    const int32_t component_index = variant.component_begin + c;
                    if (component_index < 0 || component_index >=
                            static_cast<int32_t>(_components.size())) continue;
                    if (_components[component_index].good_id == output_good)
                        matching_score = saturating_add(matching_score, score, sat);
                }
            }
            if (score_sum > 0 && matching_score > 0)
                target = saturating_add(target, mul_div_sat(desired,
                    matching_score, score_sum, sat), sat);
        }
        return std::max<int64_t>(0, target);
        };
        if (reuse_retention) {
            const auto found = memo.retention_targets.find(key);
            if (found != memo.retention_targets.end()) {
                static const bool verify = [] {
                    const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_MEMO_VERIFY);
                    return value && std::strcmp(value, "1") == 0;
                }();
                if (verify) {
                    int64_t reference_sat = 0;
                    const int64_t reference = compute(reference_sat);
                    if (reference != found->second.first || reference_sat != found->second.second) {
                        std::fprintf(stderr, "[owner-retention-memo-mismatch] cell=%d plan=%d good=%d\n",
                            group.cell, owner_plan_id, output_good);
                        std::abort();
                    }
                }
                sat += found->second.second;
                EconomyCostProbe::record("owner_retention.reused", _current_day.get(), 0.0, 1);
                return found->second.first;
            }
        }
        const int64_t saturation_before = sat;
        const int64_t target = compute(sat);
        if (reuse_retention)
            memo.retention_targets.emplace(key, std::make_pair(target, sat - saturation_before));
        EconomyCostProbe::record("owner_retention.computed", _current_day.get(), 0.0, 1);
        return target;
    };
    if (quote_trace) add_quote_section(quote_sections.setup_ms, quote_setup_started);
    thread_local std::vector<int32_t> quoted_input_candidates;
    quoted_input_candidates.clear();
    quoted_input_candidates.reserve(static_cast<size_t>(std::max(0, type.input_count)));
    // The first output pass already evaluates the per-output quantity at this
    // throughput scale; the fundable-output pass reuses it instead of running
    // the same climate/count math a second time.
    thread_local std::vector<int64_t> quoted_output_quantities;
    quoted_output_quantities.assign(
        static_cast<size_t>(std::max(0, type.output_count)), 0);
    const auto quote_input_scan_started = Clock::now();
    // Soft inputs are optional productivity at the objective activity scale.
    // Track bare (stock coverage) and tooled (buy soft) efficiencies.
    int64_t soft_efficiency_bare_q16 = Q16_ONE;
    int64_t soft_efficiency_tooled_q16 = Q16_ONE;
    bool has_soft_partial_input = false;
    for (int32_t i = 0; i < type.input_count; ++i) {
        const ProductionInput &input = _building_inputs[type.input_begin + i];
        const int64_t required = std::clamp<int64_t>(input.required_q16, 0, Q16_ONE);
        int32_t best_candidate = -1;
        int64_t best_raw_capacity = -1;
        int64_t best_cost = std::numeric_limits<int64_t>::max();
        for (int32_t c = input.candidate_begin;
             c < input.candidate_begin + input.candidate_count; ++c) {
            const InputCandidate &candidate = _building_input_candidates[c];
            if (!good_input_candidate_available(group.cell, candidate.good_id, true)) continue;
            const int64_t raw = saturating_mul(group.count, input.quantity, sat);
            const int64_t physical_numerator = saturating_add(
                saturating_mul(raw, Q16_ONE, sat),
                std::max<int32_t>(0, candidate.efficiency_q16) - 1, sat);
            const int64_t physical = effective_production_input_quantity(
                group.cell, candidate.good_id,
                physical_numerator / std::max<int32_t>(1, candidate.efficiency_q16), sat);
            const int32_t idx = market_store().index(market, candidate.good_id);
            const int64_t stock = std::max<int64_t>(0, market_store().stock[idx]);
            const int64_t raw_capacity = physical > 0
                ? std::clamp<int64_t>(mul_div_sat(stock, Q16_ONE,
                    physical, sat), 0, Q16_ONE) : Q16_ONE;
            const int64_t cost = mul_div_sat(physical, market_store().price[idx],
                GOODS_SCALE, sat);
            if (raw_capacity > best_raw_capacity || (raw_capacity == best_raw_capacity &&
                (cost < best_cost || (cost == best_cost && (best_candidate < 0 ||
                    candidate.good_id < _building_input_candidates[best_candidate].good_id))))) {
                best_candidate = c;
                best_raw_capacity = raw_capacity;
                best_cost = cost;
            }
        }
        if (best_candidate < 0) {
            if (required >= Q16_ONE) { quote.prospective_scale_q16 = 0;
                quote.executable_capacity_q16 = 0; return quote; }
            if (required > 0 && required < Q16_ONE) {
                has_soft_partial_input = true;
                const int64_t bare = Q16_ONE - required;
                soft_efficiency_bare_q16 = std::min(soft_efficiency_bare_q16, bare);
                soft_efficiency_tooled_q16 = std::min(soft_efficiency_tooled_q16, bare);
            }
            quoted_input_candidates.push_back(-1);
            continue;
        }
        if (required >= Q16_ONE) {
            scale = std::min(scale, best_raw_capacity);
        } else if (required > 0) {
            has_soft_partial_input = true;
            soft_efficiency_bare_q16 = std::min<int64_t>(
                soft_efficiency_bare_q16,
                Q16_ONE - required + mul_div_sat(
                    best_raw_capacity, required, Q16_ONE, sat));
            // Buying soft restores full soft productivity for this slot.
            soft_efficiency_tooled_q16 = std::min<int64_t>(
                soft_efficiency_tooled_q16, Q16_ONE);
        }
        quoted_input_candidates.push_back(best_candidate);
    }
    if (quote_trace)
        add_quote_section(quote_sections.input_scan_ms, quote_input_scan_started);
    auto purchase_input_cost_at_scale = [&](int64_t eval_scale,
                                            bool buy_soft) -> int64_t {
        int64_t total = 0;
        for (int32_t i = 0; i < type.input_count; ++i) {
            const ProductionInput &input = _building_inputs[type.input_begin + i];
            const int32_t best_candidate = i < static_cast<int32_t>(
                quoted_input_candidates.size()) ? quoted_input_candidates[i] : -1;
            const int64_t required = std::clamp<int64_t>(input.required_q16, 0, Q16_ONE);
            if (best_candidate < 0 || required <= 0) continue;
            if (required < Q16_ONE && !buy_soft) continue;
            const InputCandidate &candidate = _building_input_candidates[best_candidate];
            const int64_t raw = saturating_mul(group.count, input.quantity, sat);
            const int64_t physical_numerator = saturating_add(
                saturating_mul(raw, Q16_ONE, sat),
                std::max<int32_t>(0, candidate.efficiency_q16) - 1, sat);
            const int64_t physical = effective_production_input_quantity(
                group.cell, candidate.good_id,
                physical_numerator / std::max<int32_t>(1, candidate.efficiency_q16), sat);
            const int64_t purchase_scale = std::clamp<int64_t>(eval_scale, 0, Q16_ONE);
            const int64_t quantity = mul_div_sat(physical, purchase_scale,
                Q16_ONE, sat);
            const int64_t base_cost = mul_div_sat(quantity,
                market_store().price[market_store().index(market, candidate.good_id)],
                GOODS_SCALE, sat);
            const int32_t transaction_rate = frozen_tax_rate(
                group.cell, NativeCountryRuntime::TAX_TRANSACTION,
                candidate.good_id);
            const int64_t input_transfer = expected_fiscal_transfer(
                group.cell, NativeCountryRuntime::TAX_TRANSACTION, base_cost,
                transaction_rate, sat);
            total = saturating_add(total,
                std::max<int64_t>(0, saturating_add(base_cost, input_transfer, sat)),
                sat);
        }
        return total;
    };
    // Existing owners must fund the inputs production would actually buy at
    // the evaluated scale. Vacant lots skip this: employment/investment
    // validates sponsor capital on transfer. The owner cash headroom does not
    // depend on buy_soft/eval_scale, so it is resolved once per quote and
    // shared by the tooled and bare clamps instead of re-running
    // living_cost_for_signature for the same cell/signature twice.
    int64_t owner_cash_headroom = 0;
    bool owner_cash_headroom_ready = false;
    const auto owner_available_cash = [&]() -> int64_t {
        if (!owner_cash_headroom_ready) {
            owner_cash_headroom_ready = true;
            if (group.filled_owner > 0 && owner_slot >= 0) {
                const int64_t funds = std::max<int64_t>(0,
                    population_store().funds[owner_slot]);
                const int64_t people = std::max<int64_t>(1,
                    population_store().population[owner_slot]);
                const int64_t reserve = saturating_mul(saturating_mul(
                    living_cost_for_signature(group.cell,
                        group.owner_signature_id, -1, sat), people, sat), 30,
                    sat);
                owner_cash_headroom = std::max<int64_t>(0, funds - reserve);
            }
        }
        return owner_cash_headroom;
    };
    auto clamp_scale_to_owner_funds = [&](int64_t eval_scale,
                                          bool buy_soft) -> int64_t {
        if (group.filled_owner <= 0) return eval_scale;
        const int64_t purchase_bill = purchase_input_cost_at_scale(
            eval_scale, buy_soft);
        if (purchase_bill <= 0) return eval_scale;
        if (owner_slot < 0) return eval_scale;
        const auto clamp_headroom_started = Clock::now();
        const int64_t available = owner_available_cash();
        if (quote_trace)
            add_quote_section(quote_sections.clamp_headroom_ms,
                              clamp_headroom_started);
        return std::min(eval_scale, std::clamp<int64_t>(mul_div_sat(
            available, Q16_ONE, purchase_bill, sat), 0, Q16_ONE));
    };
    // Scale-independent output quote inputs shared by the tooled and bare
    // finalize passes. Nothing mutates between the two passes, so hoisting the
    // market lookups, retention targets and prior sell/share lanes removes the
    // duplicated work from the second pass while per-pass arithmetic order is
    // unchanged.
    const int32_t hoisted_output_count = type.output_count;
    thread_local std::vector<int32_t> hoisted_signal;
    thread_local std::vector<int32_t> hoisted_lane;
    thread_local std::vector<int64_t> hoisted_issue_value;
    thread_local std::vector<int64_t> hoisted_retention_target;
    thread_local std::vector<int64_t> hoisted_prior_sellable;
    thread_local std::vector<int64_t> hoisted_prior_merchant_sold;
    thread_local std::vector<int64_t> hoisted_price;
    thread_local std::vector<int64_t> hoisted_floor_unit;
    if (hoisted_output_count > 0) {
        const size_t hoisted_size = static_cast<size_t>(hoisted_output_count);
        hoisted_signal.assign(hoisted_size, -1);
        hoisted_lane.assign(hoisted_size, -1);
        hoisted_issue_value.assign(hoisted_size, 0);
        hoisted_retention_target.assign(hoisted_size, 0);
        hoisted_prior_sellable.assign(hoisted_size, 0);
        hoisted_prior_merchant_sold.assign(hoisted_size, 0);
        hoisted_price.assign(hoisted_size, 0);
        hoisted_floor_unit.assign(hoisted_size, 0);
        for (int32_t hoisted = 0; hoisted < hoisted_output_count; ++hoisted) {
            const size_t slot = static_cast<size_t>(hoisted);
            const GoodAmount &output =
                _building_outputs[type.output_begin + hoisted];
            const int32_t signal = market_signal_index(group.cell, output.good_id);
            hoisted_signal[slot] = signal;
            hoisted_lane[slot] = market_store().index(market, output.good_id);
            hoisted_issue_value[slot] = output.good_id >= 0 && output.good_id <
                    static_cast<int32_t>(_good_monetary_issue_values.size())
                ? _good_monetary_issue_values[output.good_id] : 0;
            hoisted_retention_target[slot] =
                output_retention_target(output.good_id);
            hoisted_price[slot] = std::max<int64_t>(0,
                market_store().price[hoisted_lane[slot]]);
            hoisted_prior_sellable[slot] = signal >= 0 && signal <
                    static_cast<int32_t>(_epoch_previous_producer_sellable.size())
                ? std::max<int64_t>(0, _epoch_previous_producer_sellable[signal]) : 0;
            hoisted_prior_merchant_sold[slot] = signal >= 0 && signal <
                    static_cast<int32_t>(_epoch_previous_producer_merchant_sold.size())
                ? std::clamp<int64_t>(
                    _epoch_previous_producer_merchant_sold[signal], 0,
                    hoisted_prior_sellable[slot]) : 0;
            const int64_t retention = hoisted_retention_target[slot];
            if (retention > 0 && output.good_id >= 0 && output.good_id <
                    static_cast<int32_t>(_survival_food_good_mask.size()) &&
                _survival_food_good_mask[output.good_id] != 0 &&
                output.good_id < static_cast<int32_t>(
                    _good_food_equivalent_q16.size())) {
                const int64_t food_eq_coeff = std::max<int64_t>(0,
                    _good_food_equivalent_q16[static_cast<size_t>(output.good_id)]);
                const int64_t living = group.cell >= 0 &&
                        group.cell < static_cast<int32_t>(
                            _cell_living_cost_per_capita.size())
                    ? std::max<int64_t>(0,
                        _cell_living_cost_per_capita[group.cell]) : 0;
                const int64_t survival_ration = std::max<int64_t>(
                    1, _carrying_survival_food_per_person);
                if (food_eq_coeff > 0 && living > 0) {
                    hoisted_floor_unit[slot] = mul_div_sat(
                        saturating_mul(living, food_eq_coeff, sat),
                        GOODS_SCALE,
                        saturating_mul(Q16_ONE, survival_ration, sat),
                        sat);
                }
            }
        }
    }
    auto finalize_at_scale = [&](int64_t activity_scale,
                                  bool buy_soft) -> OwnerOpportunityQuote {
        const auto fin_pre_started = Clock::now();
        OwnerOpportunityQuote result = quote;
        result.cell = group.cell;
        result.type_id = group.type_id;
        result.owner_signature_id = group.owner_signature_id;
        result.owner_slots = saturating_mul(group.count,
            std::max<int64_t>(1, type.owner_slots_per_building), sat);
        result.employee_slots = 0;
        for (int32_t r = 0; r < type.employee_count; ++r) {
            const JobRole &role = _building_employee_roles[type.employee_begin + r];
            result.employee_slots = saturating_add(result.employee_slots,
                saturating_mul(group.count,
                    std::max<int64_t>(0, role.slots_per_building), sat), sat);
        }
        result.owner_jobs_filled = has_owner_cohort ? result.owner_slots : 0;
        result.employee_jobs_filled = 0;
        activity_scale = std::clamp<int64_t>(activity_scale, 0, Q16_ONE);
        const int64_t soft_eff = buy_soft
            ? soft_efficiency_tooled_q16 : soft_efficiency_bare_q16;
        const int64_t throughput_scale = mul_div_sat(
            activity_scale, soft_eff, Q16_ONE, sat);
        result.prospective_scale_q16 = activity_scale;
        result.executable_capacity_q16 = throughput_scale;
        result.soft_productivity_q16 = soft_eff;
        result.natural_capacity_q16 = quote.natural_capacity_q16;
        result.owner_run_q16 = quote.owner_run_q16;
        result.climate_factor_q16 = quote.climate_factor_q16;
        result.resource_factor_q16 = quote.resource_factor_q16;
        result.natural_max_output = 0;
        if (quote_trace) add_quote_section(quote_sections.fin_pre_ms, fin_pre_started);
        const auto fin_natural_started = Clock::now();
        const int64_t natural_throughput_q16 = mul_div_sat(
            quote.natural_capacity_q16, soft_eff, Q16_ONE, sat);
        for (int32_t ni = 0; ni < type.output_count; ++ni) {
            const GoodAmount &natural_output = _building_outputs[
                type.output_begin + ni];
            result.natural_max_output = saturating_add(
                result.natural_max_output,
                effective_building_output_quantity(
                    group, natural_output.good_id, natural_output.quantity,
                    natural_throughput_q16, std::max<int64_t>(1, group.count), sat),
                sat);
        }
        if (quote_trace) add_quote_section(quote_sections.fin_natural_ms, fin_natural_started);
        result.wages = mul_div_sat(wages_at_full_scale, throughput_scale, Q16_ONE, sat);
        result.maintenance = mul_div_sat(
            maintenance_at_full_scale, throughput_scale, Q16_ONE, sat);
        const auto fin_input_cost_started = Clock::now();
        result.input_cost = purchase_input_cost_at_scale(activity_scale, buy_soft);
        if (quote_trace) add_quote_section(quote_sections.fin_input_cost_ms, fin_input_cost_started);
        result.cash_receipt = 0;
        int64_t merchant_cash_receipt = 0;
        int64_t producer_support_cash_receipt = 0;
        result.in_kind_retail_value = 0;
        result.monetary_quote_capped = false;
        result.monetary_quota_absorption_q16 = 0;
        result.business_transfer = 0;
        result.income_transfer = 0;
        result.owner_income_per_day = 0;
        result.disposable_survival_power_per_day = 0;
        result.feasible = false;
        result.survival_priority = false;
        const auto fin_outputs_started = Clock::now();
        for (int32_t i = 0; i < type.output_count; ++i) {
            const GoodAmount &output = _building_outputs[type.output_begin + i];
            // Group-level daily quote: per-building recipe × installed count.
            const int64_t quantity = effective_building_output_quantity(
                group, output.good_id, output.quantity, throughput_scale,
                std::max<int64_t>(1, group.count), sat);
            if (i < static_cast<int32_t>(quoted_output_quantities.size()))
                quoted_output_quantities[static_cast<size_t>(i)] = quantity;
            if (quantity <= 0) continue;
            const size_t output_slot = static_cast<size_t>(i);
            const int32_t output_signal = hoisted_signal[output_slot];
            const int32_t output_lane = hoisted_lane[output_slot];
            // The owner cohort was resolved once at function entry; reuse the
            // verdict instead of scanning the cell pages again for every
            // output and both quote variants.
            // Shadow-only derived demand must not invent a cold-start owner
            // for vacant lots when no real business EMA exists yet.
            if (!has_owner_cohort &&
                output_signal >= 0 && output_signal < static_cast<int32_t>(
                    _epoch_derived_business_demand.size()) &&
                _epoch_derived_business_demand[output_signal] > 0 &&
                output_signal < static_cast<int32_t>(
                    _market_signals.business_demand_ema.size()) &&
                _market_signals.business_demand_ema[output_signal] <= 0 &&
                epoch_procurement_demand_daily(group.cell, output.good_id) <= 0) {
                continue;
            }
            // Counterfactual quotes still value sellable output at market
            // prices even when the lane is empty — otherwise vacant workshops
            // bill inputs with zero revenue and look permanently loss-making.
            const int64_t issue_value = hoisted_issue_value[output_slot];
            const int64_t retained = std::min(quantity,
                hoisted_retention_target[output_slot]);
            const int64_t sellable = std::max<int64_t>(0, quantity - retained);
            int64_t merchant_quantity = sellable;
            int64_t support_quantity = 0;
            int64_t merchant_unit_price = 0;
            if (issue_value > 0) {
                // Face × sellable output. Do not shrink the quote by the cell
                // bullion pool — that made income look quota-limited.
                merchant_quantity = 0;
                support_quantity = sellable;
                result.monetary_quote_capped = false;
                result.monetary_quota_absorption_q16 = sellable > 0 ? Q16_ONE : 0;
            } else {
                const int32_t signal = output_signal;
                const int64_t target = merchant_inventory_target(market,
                    output.good_id, signal, signal >= 0 ?
                    _market_signals.realized_withdrawal_ema[signal] : 0, 0,
                    quantity, sat);
                const int32_t buy_factor = effective_merchant_buy_factor_q16(
                    market, output.good_id, target,
                    market_store().stock[output_lane], sat);
                merchant_unit_price = mul_div_sat(
                    market_store().price[output_lane], buy_factor, Q16_ONE, sat);
                const int64_t prior_sellable =
                    hoisted_prior_sellable[output_slot];
                const int64_t prior_merchant_sold =
                    hoisted_prior_merchant_sold[output_slot];
                if (prior_sellable > 0) {
                    const int64_t merchant_share_q16 = std::clamp<int64_t>(
                        mul_div_sat(prior_merchant_sold, Q16_ONE,
                            prior_sellable, sat), 0, Q16_ONE);
                    merchant_quantity = mul_div_sat(sellable,
                        merchant_share_q16, Q16_ONE, sat);
                }
                support_quantity = std::max<int64_t>(0,
                    sellable - merchant_quantity);
            }
            merchant_cash_receipt = saturating_add(merchant_cash_receipt,
                mul_div_sat(merchant_quantity, merchant_unit_price,
                    GOODS_SCALE, sat), sat);
            producer_support_cash_receipt = saturating_add(
                producer_support_cash_receipt,
                producer_support_receipt_value(group.cell, output.good_id,
                    support_quantity, sat), sat);
            // Self-provisioned survival food is livelihood, not a thin market
            // scrap; its living-cost floor is scale-independent and was hoisted.
            const int64_t unit_price = std::max<int64_t>(
                hoisted_price[output_slot], hoisted_floor_unit[output_slot]);
            result.in_kind_retail_value = saturating_add(
                result.in_kind_retail_value,
                mul_div_sat(retained, unit_price, GOODS_SCALE, sat), sat);
        }
        result.cash_receipt = saturating_add(merchant_cash_receipt,
            producer_support_cash_receipt, sat);
        if (quote_trace) add_quote_section(quote_sections.fin_outputs_ms, fin_outputs_started);
        const auto fin_income_started = Clock::now();
        const int64_t operating_cost = saturating_add(
            saturating_add(result.input_cost, result.wages, sat),
            result.maintenance, sat);
        const int64_t absolute_building_days = saturating_mul(
            group.count, std::max<int64_t>(1, _epoch_days.get()), sat);
        const int32_t profession = group.owner_signature_id >= 0 &&
                group.owner_signature_id < static_cast<int32_t>(_signatures.size())
            ? _signatures[group.owner_signature_id].profession_id : -1;
        const int64_t absolute_owner_days = saturating_mul(
            std::max<int64_t>(1, group.count), std::max<int64_t>(1, _epoch_days.get()), sat);
        const BuildingTaxQuote tax_quote = expected_building_tax_quote(
            group.cell, group.type_id, profession, merchant_cash_receipt,
            producer_support_cash_receipt, operating_cost, operating_cost,
            result.owner_living_cost, absolute_building_days,
            absolute_owner_days, sat);
        result.business_transfer = tax_quote.business_transfer;
        result.income_transfer = tax_quote.income_transfer;
        const int64_t pre_income = saturating_sub(
            saturating_sub(merchant_cash_receipt, operating_cost, sat),
            result.business_transfer, sat);
        const int64_t pool = saturating_add(saturating_add(
            saturating_sub(saturating_sub(pre_income,
                result.owner_living_cost, sat), result.income_transfer, sat),
            producer_support_cash_receipt, sat), result.in_kind_retail_value, sat);
        // Per-owner daily disposable: group residual ÷ nameplate owner seats.
        const int64_t per_owner = pool / std::max<int64_t>(1, owner_slots);
        result.owner_income_per_day = per_owner;
        result.disposable_survival_power_per_day = per_owner;
        result.feasible = result.cash_receipt > 0 || result.in_kind_retail_value > 0;
        for (int32_t i = 0; i < type.output_count; ++i) {
            const int32_t good = _building_outputs[type.output_begin + i].good_id;
            if (good >= 0 && good < static_cast<int32_t>(_survival_food_good_mask.size()) &&
                _survival_food_good_mask[good] != 0) {
                // Hungry mobility prefers any feasible self-provisioning food
                // lot, not only cells already reporting a shortage spike.
                result.survival_priority = result.feasible;
                break;
            }
        }
        // Normalized economic decomposition.  These fields are projections of
        // the same quote used by employment; investment and diagnostics must
        // consume this result instead of recomputing a second receipt path.
        if (quote_trace) add_quote_section(quote_sections.fin_income_ms, fin_income_started);
        const auto fin_proj_started = Clock::now();
        result.utilization_q16 = result.executable_capacity_q16;
        result.owner_use_value_per_day = result.in_kind_retail_value;
        result.merchant_revenue_per_day = merchant_cash_receipt;
        result.producer_support_revenue_per_day = producer_support_cash_receipt;
        result.cash_revenue_per_day = result.cash_receipt;
        result.economic_revenue_per_day = saturating_add(
            result.cash_receipt, result.in_kind_retail_value, sat);
        result.input_cost_per_day = result.input_cost;
        result.wage_cost_per_day = result.wages;
        result.maintenance_cost_per_day = result.maintenance;
        result.owner_living_cost_per_day = result.owner_living_cost;
        result.after_tax_revenue_per_day = std::max<int64_t>(0,
            tax_quote.after_tax_cash);
        result.profit_per_day = result.owner_income_per_day;
        result.fundable_output = 0;
        result.actual_output = 0;
        for (int32_t oi = 0; oi < type.output_count; ++oi) {
            const size_t cache_index = static_cast<size_t>(oi);
            const int64_t quantity = cache_index < quoted_output_quantities.size()
                ? quoted_output_quantities[cache_index] : 0;
            result.fundable_output = saturating_add(result.fundable_output,
                quantity, sat);
        }
        result.actual_output = result.fundable_output;
        result.fixed_cost = saturating_add(result.maintenance,
            result.wages, sat);
        result.variable_cost = result.input_cost;
        result.affordable_wage_per_day = result.employee_slots > 0
            ? std::max<int64_t>(0, saturating_sub(
                saturating_sub(result.after_tax_revenue_per_day,
                    result.input_cost, sat), result.maintenance, sat)) /
                result.employee_slots
            : 0;
        if (quote_trace) add_quote_section(quote_sections.fin_proj_ms, fin_proj_started);
        return result;
    };

    const int64_t activity_scale = scale;
    const auto quote_finalize_started = Clock::now();
    const auto quote_clamp_tooled_started = Clock::now();
    const int64_t tooled_scale =
        clamp_scale_to_owner_funds(activity_scale, true);
    if (quote_trace)
        add_quote_section(quote_sections.funds_clamp_ms, quote_clamp_tooled_started);
    OwnerOpportunityQuote tooled = finalize_at_scale(tooled_scale, true);
    if (quote_trace)
        add_quote_section(quote_sections.finalize_tooled_ms,
                          quote_finalize_started);
    OwnerOpportunityQuote best = tooled;
    if (has_soft_partial_input ||
        soft_efficiency_bare_q16 < Q16_ONE ||
        soft_efficiency_tooled_q16 < Q16_ONE) {
        EconomyCostProbe::record("owner_quote.double_eval", _current_day.get(),
                                 0.0, 1);
        if (has_soft_partial_input) {
            EconomyCostProbe::record("owner_quote.de_soft_partial",
                                     _current_day.get(), 0.0, 1);
        }
        if (soft_efficiency_bare_q16 < Q16_ONE) {
            EconomyCostProbe::record("owner_quote.de_bare_lt1",
                                     _current_day.get(), 0.0, 1);
        }
        if (soft_efficiency_tooled_q16 < Q16_ONE) {
            EconomyCostProbe::record("owner_quote.de_tooled_lt1",
                                     _current_day.get(), 0.0, 1);
        }
        const auto quote_bare_started = Clock::now();
        const auto quote_clamp_bare_started = Clock::now();
        const int64_t bare_scale =
            clamp_scale_to_owner_funds(activity_scale, false);
        if (quote_trace)
            add_quote_section(quote_sections.funds_clamp_bare_ms,
                              quote_clamp_bare_started);
        OwnerOpportunityQuote bare = finalize_at_scale(bare_scale, false);
        if (quote_trace)
            add_quote_section(quote_sections.finalize_bare_ms,
                              quote_bare_started);
        // Prefer the scale production would choose: higher disposable first.
        if (bare.owner_income_per_day > best.owner_income_per_day ||
            (bare.owner_income_per_day == best.owner_income_per_day &&
             bare.executable_capacity_q16 > best.executable_capacity_q16)) {
            best = bare;
        }
    }
    if (quote_trace) ++quote_sections.calls;
    return best;
}

void NativeEconomyRuntime::reconcile_family_branch_effects(
        uint64_t branch_handle, bool submit_changes) {
    int32_t branch = -1, family = -1;
    if (!family_influences().valid_handle(branch_handle, branch) ||
        !families_store().valid_handle(family_influences().family_handle[branch], family))
        return;
    const int32_t level = family_influences().prestige_level[branch];
    const uint64_t branch_stable_id = static_cast<uint64_t>(
        family_influences().stable_id[branch]);
    const uint32_t branch_generation = static_cast<uint32_t>(branch_handle >> 32U);
    auto stable_effect_instance_id = [&](const std::string &definition_key) {
        uint64_t identity = trace_hash_mix(1469598103934665603ULL,
            branch_stable_id);
        identity = trace_hash_mix(identity, static_cast<uint32_t>(
            family_influences().cell[branch]));
        uint64_t definition_hash = 1469598103934665603ULL;
        for (unsigned char ch : definition_key)
            definition_hash = trace_hash_mix(definition_hash, ch);
        identity = trace_hash_mix(identity, definition_hash);
        return static_cast<int64_t>(identity & 0x7fffffffffffffffULL);
    };
    // The other identity shape in this file. The founding random-pool grant
    // (grant_family_effect_to_branches) and the trait path above mix the target
    // cell in, because a neighbour-targeted effect owns one instance per target.
    // grant_ancestral_precept_for_country does not, so a (branch, key) pair can
    // legitimately exist under either shape.
    auto shaped_effect_instance_id = [&](const std::string &definition_key,
                                         int32_t target_cell) {
        uint64_t identity = trace_hash_mix(1469598103934665603ULL,
            branch_stable_id);
        identity = trace_hash_mix(identity, static_cast<uint32_t>(
            family_influences().cell[branch]));
        identity = trace_hash_mix(identity, static_cast<uint32_t>(
            std::max(0, target_cell)));
        uint64_t definition_hash = 1469598103934665603ULL;
        for (unsigned char ch : definition_key)
            definition_hash = trace_hash_mix(definition_hash, ch);
        identity = trace_hash_mix(identity, definition_hash);
        return static_cast<int64_t>(identity & 0x7fffffffffffffffLL);
    };
    // Restore rebuild asks "is this instance still alive", and that question has
    // to go to whichever side owns EFFECT. EffectRuntime::has_instance_pod only
    // answers for the legacy authority: under EFFECT worker authority the main
    // thread is a writeback mirror, so every worker-owned instance read as absent
    // and the binding was dropped -- which then also leaked the instance, because
    // clear_family_branch_effects retires by binding.
    auto instance_alive = [&](int64_t instance_id) {
        bool exists = false;
        if (!effect_pod_instance_exists(_effect_runtime, _effect_forwarder,
                instance_id, branch_generation, exists))
            return false;
        return exists;
    };
    auto resolve_effect_target = [&](const std::string &definition_key,
                                     uint64_t &target_handle,
                                     uint32_t &target_generation,
                                     EffectRuntime::FamilyEffectMetadataPod &metadata)
                                     -> bool {
        if (_effect_runtime == nullptr ||
            !_effect_runtime->family_effect_metadata_pod(
                definition_key, metadata))
            return false;
        const int32_t cell = family_influences().cell[branch];
        auto source_country = [&]() -> bool {
            if (_country_runtime == nullptr) return false;
            target_handle = static_cast<uint64_t>(
                country_reads().country_handle_for_cell(cell));
            if (target_handle == 0) return false;
            target_generation = static_cast<uint32_t>(target_handle >> 32U);
            return target_generation != 0;
        };
        if (metadata.target_selector_kind == 1) { // SOURCE_BRANCH.
            if (metadata.target_domain != 1) return false;
            target_handle = branch_handle;
            target_generation = branch_generation;
            // Every other branch of this resolver rejects a zero generation; so
            // must this one. A domain-1 (Branch) row with generation 0 passes
            // the forwarder and is then rejected by the pod's own identity
            // check, which surfaces as a family effect that silently never
            // exists instead of a resolver that declined the target.
            return target_generation != 0;
        }
        if (metadata.target_selector_kind == 2) { // SOURCE_CELL.
            if (metadata.target_domain != 2 && metadata.target_domain != 4 &&
                metadata.target_domain != 5) return false;
            if (cell < 0 || cell >= _cell_count.get()) return false;
            target_handle = static_cast<uint64_t>(cell);
            target_generation = 1;
            return true;
        }
        if (metadata.target_selector_kind == 3) { // SOURCE_COUNTRY.
            return metadata.target_domain == 3 && source_country();
        }
        if (metadata.target_selector_kind == 4) { // STATIC_HANDLE.
            const char *begin = metadata.target_selector_id.data();
            const char *end = begin + metadata.target_selector_id.size();
            uint64_t parsed = 0;
            const auto result = std::from_chars(begin, end, parsed);
            if (result.ec != std::errc{} || result.ptr != end || parsed == 0)
                return false;
            target_handle = parsed;
            target_generation = metadata.target_domain == 2 ||
                    metadata.target_domain == 4 || metadata.target_domain == 5
                ? 1 : static_cast<uint32_t>(parsed >> 32U);
            return target_generation != 0;
        }
        if (metadata.target_selector_kind == 5) { // SELECTOR_ID.
            if (metadata.target_domain != 5 || cell < 0 || cell >= _cell_count.get())
                return false;
            const std::string &selector = metadata.target_selector_id;
            const bool known = std::binary_search(_building_type_ids.begin(),
                    _building_type_ids.end(), selector) ||
                std::binary_search(_resource_ids.begin(), _resource_ids.end(),
                                   selector) ||
                std::binary_search(_good_ids.begin(), _good_ids.end(), selector);
            if (!known) return false;
            target_handle = static_cast<uint64_t>(cell);
            target_generation = 1;
            return true;
        }
        switch (metadata.target_domain) {
            case 0: // Family.
                target_handle = family_influences().family_handle[branch];
                target_generation = static_cast<uint32_t>(target_handle >> 32U);
                break;
            case 1: // Branch.
                target_handle = branch_handle;
                target_generation = branch_generation;
                break;
            case 2: // Settlement cell.
            case 4: // Climate cell.
            case 5: // Building/resource selector is evaluated within the cell.
                if (cell < 0 || cell >= _cell_count.get()) return false;
                target_handle = static_cast<uint64_t>(cell);
                target_generation = 1;
                break;
            case 3: // Country owning the source branch cell.
                return source_country();
            default:
                return false;
        }
        return target_generation != 0;
    };
    auto submit_effect_instance = [&](const std::string &definition_key,
                                      int32_t magnitude_q16) -> bool {
        if (_effect_runtime == nullptr || !submit_changes) return false;
        const uint64_t stable_id = static_cast<uint64_t>(
            family_influences().stable_id[branch]);
        uint64_t identity = trace_hash_mix(1469598103934665603ULL, stable_id);
        identity = trace_hash_mix(identity, static_cast<uint32_t>(
            family_influences().cell[branch]));
        uint64_t definition_hash = 1469598103934665603ULL;
        for (unsigned char ch : definition_key)
            definition_hash = trace_hash_mix(definition_hash, ch);
        identity = trace_hash_mix(identity, definition_hash);
        const int64_t instance_id = static_cast<int64_t>(identity &
            0x7fffffffffffffffULL);
        const uint32_t generation = static_cast<uint32_t>(branch_handle >> 32U);
        std::string error;
        if (!effect_pod_upsert(_effect_runtime, _effect_forwarder, instance_id,
                std::string("family.modifier.") + definition_key, generation,
                0x46414d494c59, static_cast<int64_t>(stable_id), branch_handle,
                stable_id,
                static_cast<uint32_t>(family_influences().cell[branch]), 0,
                _current_day.get(), -1, true, error))
            return false;
        if (!effect_pod_metric(_effect_runtime, _effect_forwarder, instance_id,
                generation, 0, family_effect_metric_revision(1), magnitude_q16,
                error))
            return false;
        return true;
    };
    std::unordered_map<std::string, int32_t> desired;
    std::unordered_map<std::string, int32_t> desired_effects;
    std::unordered_map<std::string, int32_t> desired_triggers;
    const uint64_t family_handle = family_influences().family_handle[branch];
    const auto trait_begin = std::lower_bound(family_trait_rolls().begin(),
        family_trait_rolls().end(), family_handle,
        [](const FamilyTraitRoll &roll, uint64_t handle) {
            return roll.family_handle < handle;
        });
    const auto trait_end = std::upper_bound(trait_begin, family_trait_rolls().end(),
        family_handle, [](uint64_t handle, const FamilyTraitRoll &roll) {
            return handle < roll.family_handle;
        });
    for (auto trait_it = trait_begin; trait_it != trait_end; ++trait_it) {
        const FamilyTraitRoll &roll = *trait_it;
        if (roll.trait_id < 0 || roll.trait_id >= static_cast<int32_t>(
                _family_trait_modifier_offsets.size()) - 1) continue;
        for (int32_t edge = _family_trait_modifier_offsets[roll.trait_id];
             edge < _family_trait_modifier_offsets[roll.trait_id + 1]; ++edge) {
            if (_family_trait_modifier_targets[edge] != 0) continue;
            const int32_t tier_magnitude =
                _family_trait_modifier_tier_magnitudes_q16[edge * 6 + level];
            const int64_t scaled = static_cast<int64_t>(tier_magnitude) *
                roll.strength_q16 / Q16_ONE;
            int32_t &value = desired[
                _family_trait_modifier_definition_keys[edge]];
            value = std::clamp<int64_t>(static_cast<int64_t>(value) + scaled,
                                        0, 4 * Q16_ONE);
        }
        if (roll.trait_id < static_cast<int32_t>(
                _family_trait_effect_offsets.size()) - 1) {
            for (int32_t edge = _family_trait_effect_offsets[roll.trait_id];
                 edge < _family_trait_effect_offsets[roll.trait_id + 1]; ++edge) {
                const std::string &key = _family_trait_effect_keys[edge];
                int32_t tier = Q16_ONE;
                const int32_t effect_id = family_effect_id_for_key(key);
                if (effect_id >= 0)
                    tier = family_effect_prestige_magnitude_q16(effect_id, level);
                else {
                    EffectRuntime::FamilyEffectMetadataPod metadata;
                    if (_effect_runtime != nullptr &&
                        _effect_runtime->family_effect_metadata_pod(key, metadata))
                        tier = metadata.magnitude_by_prestige_q16[
                            std::clamp(level, 0, 5)];
                }
                const int64_t scaled = static_cast<int64_t>(tier) *
                    roll.strength_q16 / Q16_ONE;
                int32_t &value = desired_effects[key];
                value = std::clamp<int64_t>(static_cast<int64_t>(value) + scaled,
                    0, 4 * Q16_ONE);
            }
        }
        if (roll.trait_id >= static_cast<int32_t>(
                _family_trait_trigger_offsets.size()) - 1) continue;
        for (int32_t edge = _family_trait_trigger_offsets[roll.trait_id];
             edge < _family_trait_trigger_offsets[roll.trait_id + 1]; ++edge) {
            const std::string &key =
                _family_trait_trigger_definition_keys_by_tier[edge * 6 + level];
            if (!key.empty()) desired_triggers[key] =
                _family_trait_trigger_reward_targets[edge];
        }
    }
    auto add_effect_triggers = [&](const std::string &program_key) {
        const int32_t effect_id = family_effect_id_for_key(program_key);
        if (effect_id < 0 ||
            _family_effect_trigger_definition_keys_by_tier.size() <
                static_cast<size_t>(effect_id + 1) * 6U)
            return;
        const std::string &key = _family_effect_trigger_definition_keys_by_tier[
            static_cast<size_t>(effect_id) * 6U + static_cast<size_t>(
                std::clamp(level, 0, 5))];
        if (key.empty()) return;
        const int32_t reward = effect_id < static_cast<int32_t>(
                _family_effect_trigger_reward_targets.size())
            ? _family_effect_trigger_reward_targets[static_cast<size_t>(effect_id)] : 0;
        desired_triggers[key] = reward;
    };
    if (_effect_runtime != nullptr) {
        const auto branch_bindings = _family_effect_instances_by_branch.find(
            branch_handle);
        const std::vector<int64_t> existing_instance_ids = branch_bindings ==
                _family_effect_instances_by_branch.end()
            ? std::vector<int64_t>() : branch_bindings->second;
        std::vector<std::string> desired_non_trait;
        for (const int64_t existing_instance_id : existing_instance_ids) {
            const auto indexed = _family_effect_binding_by_instance.find(
                existing_instance_id);
            if (indexed == _family_effect_binding_by_instance.end()) continue;
            const size_t binding_index = indexed->second;
            const bool remove_binding = [&] {
            auto binding_write = _family_effect_bindings.edit_row(binding_index);
            FamilyEffectBinding &binding = binding_write[0];
            const std::string definition_key = binding.definition_key;
            EffectRuntime::FamilyEffectMetadataPod metadata;
            const bool trait_source = _effect_runtime->family_effect_metadata_pod(
                    definition_key, metadata) && metadata.source_kind == 0;
            if (!trait_source) {
                if (definition_key == "family.effect.knowledge_spread" &&
                    submit_changes) {
                    desired_non_trait.push_back(definition_key);
                }
                int32_t magnitude = metadata.magnitude_by_prestige_q16[
                    std::clamp(level, 0, 5)];
                const int32_t effect_id = family_effect_id_for_key(definition_key);
                if (effect_id >= 0)
                    magnitude = family_effect_prestige_magnitude_q16(effect_id, level);
                magnitude = std::clamp(magnitude, 0,
                    static_cast<int32_t>(4 * Q16_ONE));
                if (definition_key == "family.effect.knowledge_spread" &&
                    submit_changes) {
                    std::vector<int32_t> allowed_cells;
                    collect_family_effect_target_cells(
                        family_influences().cell[branch],
                        metadata.target_selector_kind, allowed_cells,
                        definition_key, level);
                    const int32_t bound_cell = static_cast<int32_t>(
                        binding.target_handle);
                    if (std::find(allowed_cells.begin(), allowed_cells.end(),
                                  bound_cell) == allowed_cells.end()) {
                        std::string error;
                        if (effect_pod_retire(_effect_runtime, _effect_forwarder,
                                binding.instance_id, binding.generation,
                                _current_day.get(), error)) {
                            return true;
                        }
                    }
                }
                if (submit_changes && magnitude != binding.strength_q16) {
                    std::string error;
                    if (effect_pod_upsert(_effect_runtime, _effect_forwarder,
                            binding.instance_id, binding.definition_key,
                            binding.generation, 0x46414d50,
                            static_cast<int64_t>(branch_stable_id), branch_handle,
                            binding.target_handle, binding.target_generation, level,
                            _current_day.get(), -1, true, error) &&
                        effect_pod_metric(_effect_runtime, _effect_forwarder,
                            binding.instance_id, binding.generation, 0,
                            family_effect_metric_revision(1), magnitude, error)) {
                        binding.strength_q16 = magnitude;
                        mark_family_behavior_cache_dirty(
                            FAMILY_BEHAVIOR_DIRTY_EFFECT_BINDINGS);
                    }
                }
                publish_family_effect_metrics(binding,
                    family_effect_metric_revision(1),
                    MetricMask::all_declared(FAMILY_METRIC_COUNT));
                return false;
            }
            const auto found = desired_effects.find(definition_key);
            const int32_t strength = found == desired_effects.end() ? 0 : found->second;
            bool consumed = strength == binding.strength_q16;
            if (submit_changes && strength != binding.strength_q16) {
                std::string error;
                if (strength == 0) {
                    if (effect_pod_retire(_effect_runtime, _effect_forwarder,
                            binding.instance_id, binding.generation,
                            _current_day.get(), error)) {
                        desired_effects.erase(definition_key);
                        return true;
                    }
                } else if (effect_pod_upsert(_effect_runtime, _effect_forwarder,
                        binding.instance_id, binding.definition_key,
                        binding.generation, 0x46414d54,
                        static_cast<int64_t>(branch_stable_id), branch_handle,
                        binding.target_handle, binding.target_generation, level,
                        _current_day.get(), -1, true, error) &&
                        effect_pod_metric(_effect_runtime, _effect_forwarder,
                            binding.instance_id, binding.generation, 0,
                            family_effect_metric_revision(1), strength, error)) {
                    binding.strength_q16 = strength;
                    mark_family_behavior_cache_dirty(
                        FAMILY_BEHAVIOR_DIRTY_EFFECT_BINDINGS);
                    publish_family_effect_metrics(binding,
                        family_effect_metric_revision(1),
                        MetricMask::all_declared(FAMILY_METRIC_COUNT));
                    consumed = true;
                }
            }
            if (consumed && (found == desired_effects.end() ||
                    binding.strength_q16 == 0))
                desired_effects.erase(definition_key);
            else if (consumed)
                desired_effects.erase(found);
            return false;
            }();
            if (remove_binding) remove_family_effect_binding(binding_index);
        }
        for (const auto &item : desired_effects) {
            if (item.second == 0) continue;
            uint64_t base_target_handle = 0;
            uint32_t base_target_generation = 0;
            EffectRuntime::FamilyEffectMetadataPod metadata;
            if (!resolve_effect_target(item.first, base_target_handle,
                    base_target_generation, metadata))
                continue;
            add_effect_triggers(item.first);
            const bool event_once = metadata.lifecycle == 2;
            std::vector<int32_t> target_cells;
            collect_family_effect_target_cells(family_influences().cell[branch],
                metadata.target_selector_kind, target_cells, item.first, level);
            if (target_cells.empty())
                target_cells.push_back(family_influences().cell[branch]);
            for (int32_t target_cell : target_cells) {
                uint64_t identity = trace_hash_mix(1469598103934665603ULL,
                    branch_stable_id);
                identity = trace_hash_mix(identity, static_cast<uint32_t>(
                    family_influences().cell[branch]));
                identity = trace_hash_mix(identity, static_cast<uint32_t>(
                    std::max(0, target_cell)));
                uint64_t definition_hash = 1469598103934665603ULL;
                for (unsigned char ch : item.first)
                    definition_hash = trace_hash_mix(definition_hash, ch);
                identity = trace_hash_mix(identity, definition_hash);
                const int64_t instance_id = static_cast<int64_t>(identity &
                    0x7fffffffffffffffULL);
                uint64_t target_handle = base_target_handle;
                uint32_t target_generation = base_target_generation;
                // Every fan-out kind (6 and above) creates one instance per
                // resolved cell, so each instance must carry its own cell
                // handle. The old 6/7 test meant kinds 8..11 fanned out into N
                // instances that all still pointed at the anchor, which made
                // "component" and "within N" behave as N copies of one cell.
                // No shipped family program uses 8..12 (family_official_buffs
                // only declares 0/2/3/5/6), so widening this cannot move an
                // existing family number.
                if (metadata.target_selector_kind >=
                    EffectRuntime::SELECTOR_NEIGHBORS_R1) {
                    if (target_cell < 0 || target_cell >= _cell_count.get()) continue;
                    target_handle = static_cast<uint64_t>(target_cell);
                    target_generation = 1;
                }
                if (!submit_changes) {
                    if (event_once || instance_alive(instance_id)) {
                        add_family_effect_binding({branch_handle,
                            item.first, item.second, instance_id, branch_generation,
                            metadata.target_domain, target_handle,
                            target_generation, metadata.metric_mask});
                    }
                    continue;
                }
                if (event_once) {
                    add_family_effect_binding({branch_handle, item.first,
                        item.second, instance_id, branch_generation,
                        metadata.target_domain, target_handle, target_generation,
                        metadata.metric_mask});
                    continue;
                }
                std::string error;
                if (!effect_pod_upsert(_effect_runtime, _effect_forwarder,
                        instance_id, item.first, branch_generation, 0x46414d54,
                        static_cast<int64_t>(branch_stable_id), branch_handle,
                        target_handle, target_generation, level, _current_day.get(),
                        -1, true, error) ||
                    !effect_pod_metric(_effect_runtime, _effect_forwarder,
                        instance_id, branch_generation, 0,
                        family_effect_metric_revision(1), item.second, error))
                    continue;
                add_family_effect_binding({branch_handle, item.first,
                    item.second, instance_id, branch_generation,
                    metadata.target_domain, target_handle, target_generation,
                    metadata.metric_mask});
                const auto indexed = _family_effect_binding_by_instance.find(instance_id);
                if (indexed != _family_effect_binding_by_instance.end())
                    publish_family_effect_metrics(
                        _family_effect_bindings[indexed->second],
                        family_effect_metric_revision(1),
                        MetricMask::all_declared(FAMILY_METRIC_COUNT));
            }
        }
        if (!desired_non_trait.empty()) {
            std::sort(desired_non_trait.begin(), desired_non_trait.end());
            desired_non_trait.erase(std::unique(desired_non_trait.begin(),
                desired_non_trait.end()), desired_non_trait.end());
            for (const std::string &key : desired_non_trait) {
                const int32_t effect_id = family_effect_id_for_key(key);
                const int32_t magnitude = family_effect_prestige_magnitude_q16(
                    effect_id, level);
                uint64_t base_target_handle = 0;
                uint32_t base_target_generation = 0;
                EffectRuntime::FamilyEffectMetadataPod metadata;
                if (!resolve_effect_target(key, base_target_handle,
                        base_target_generation, metadata))
                    continue;
                std::vector<int32_t> target_cells;
                collect_family_effect_target_cells(family_influences().cell[branch],
                    metadata.target_selector_kind, target_cells, key, level);
                if (target_cells.empty())
                    target_cells.push_back(family_influences().cell[branch]);
                for (int32_t target_cell : target_cells) {
                    const int64_t instance_id = shaped_effect_instance_id(key, target_cell);
                    if (_family_effect_binding_by_instance.find(instance_id) !=
                        _family_effect_binding_by_instance.end())
                        continue;
                    uint64_t target_handle = base_target_handle;
                    uint32_t target_generation = base_target_generation;
                    if (metadata.target_selector_kind >=
                        EffectRuntime::SELECTOR_NEIGHBORS_R1) {
                        if (target_cell < 0 || target_cell >= _cell_count.get()) continue;
                        target_handle = static_cast<uint64_t>(target_cell);
                        target_generation = 1;
                    }
                    std::string error;
                    if (!effect_pod_upsert(_effect_runtime, _effect_forwarder,
                            instance_id, key, branch_generation, 0x46414d50,
                            static_cast<int64_t>(branch_stable_id), branch_handle,
                            target_handle, target_generation, level,
                            _current_day.get(), -1, true, error) ||
                        !effect_pod_metric(_effect_runtime, _effect_forwarder,
                            instance_id, branch_generation, 0,
                            family_effect_metric_revision(1), magnitude, error))
                        continue;
                    add_family_effect_binding({branch_handle, key, magnitude,
                        instance_id, branch_generation, metadata.target_domain,
                        target_handle, target_generation, metadata.metric_mask});
                    const auto indexed = _family_effect_binding_by_instance.find(instance_id);
                    if (indexed != _family_effect_binding_by_instance.end())
                        publish_family_effect_metrics(
                            _family_effect_bindings[indexed->second],
                            family_effect_metric_revision(1),
                            MetricMask::all_declared(FAMILY_METRIC_COUNT));
                }
            }
        }
        std::vector<std::string> sibling_independent;
        for (const FamilyEffectBinding &binding : _family_effect_bindings) {
            if (binding.branch_handle == branch_handle) continue;
            int32_t other_branch = -1;
            int32_t other_family = -1;
            if (!family_influences().valid_handle(binding.branch_handle,
                    other_branch) ||
                !families_store().valid_handle(
                    family_influences().family_handle[other_branch],
                    other_family) ||
                other_family != family)
                continue;
            EffectRuntime::FamilyEffectMetadataPod metadata;
            if (_effect_runtime == nullptr ||
                !_effect_runtime->family_effect_metadata_pod(
                    binding.definition_key, metadata) ||
                metadata.source_kind == 0)
                continue;
            bool already = false;
            for (const FamilyEffectBinding &mine : _family_effect_bindings) {
                if (mine.branch_handle == branch_handle &&
                    mine.definition_key == binding.definition_key) {
                    already = true;
                    break;
                }
            }
            if (!already)
                sibling_independent.push_back(binding.definition_key);
        }
        std::sort(sibling_independent.begin(), sibling_independent.end());
        sibling_independent.erase(std::unique(sibling_independent.begin(),
            sibling_independent.end()), sibling_independent.end());
        for (const std::string &key : sibling_independent) {
            uint64_t base_target_handle = 0;
            uint32_t base_target_generation = 0;
            EffectRuntime::FamilyEffectMetadataPod metadata;
            if (!resolve_effect_target(key, base_target_handle,
                    base_target_generation, metadata))
                continue;
            const int32_t magnitude = family_effect_prestige_magnitude_q16(
                family_effect_id_for_key(key), level);
            const bool event_once = metadata.lifecycle == 2;
            const int32_t source_cell = family_influences().cell[branch];
            std::vector<int32_t> target_cells;
            collect_family_effect_target_cells(source_cell,
                metadata.target_selector_kind, target_cells, key, level);
            if (target_cells.empty()) target_cells.push_back(source_cell);
            for (int32_t target_cell : target_cells) {
                uint64_t target_handle = base_target_handle;
                uint32_t target_generation = base_target_generation;
                if (metadata.target_selector_kind >=
                    EffectRuntime::SELECTOR_NEIGHBORS_R1) {
                    if (target_cell < 0 || target_cell >= _cell_count.get()) continue;
                    target_handle = static_cast<uint64_t>(target_cell);
                    target_generation = 1;
                }
                const int64_t instance_id =
                    metadata.target_selector_kind >=
                        EffectRuntime::SELECTOR_NEIGHBORS_R1
                    ? shaped_effect_instance_id(key, target_cell)
                    : stable_effect_instance_id(key);
                if (!submit_changes) {
                    // A sibling's instance may have been created by the founding
                    // random-pool grant, which mixes the target cell into the
                    // identity. Probe both shapes and bind the one that is alive.
                    int64_t alive_id = 0;
                    if (instance_alive(instance_id)) {
                        alive_id = instance_id;
                    } else {
                        const int64_t shaped = shaped_effect_instance_id(
                            key, target_cell);
                        if (instance_alive(shaped)) alive_id = shaped;
                    }
                    if (alive_id != 0) {
                        add_family_effect_binding({branch_handle, key, magnitude,
                            alive_id, branch_generation, metadata.target_domain,
                            target_handle, target_generation, metadata.metric_mask});
                    }
                    continue;
                }
                if (event_once) {
                    add_family_effect_binding({branch_handle, key, magnitude,
                        instance_id, branch_generation, metadata.target_domain,
                        target_handle, target_generation, metadata.metric_mask});
                    continue;
                }
                std::string error;
                if (!effect_pod_upsert(_effect_runtime, _effect_forwarder,
                        instance_id, key, branch_generation, 0x46414d54,
                        static_cast<int64_t>(branch_stable_id), branch_handle,
                        target_handle, target_generation, level, _current_day.get(),
                        -1, true, error) ||
                    !effect_pod_metric(_effect_runtime, _effect_forwarder,
                        instance_id, branch_generation, 0,
                        family_effect_metric_revision(1), magnitude, error))
                    continue;
                add_family_effect_binding({branch_handle, key, magnitude, instance_id,
                    branch_generation, metadata.target_domain, target_handle,
                    target_generation, metadata.metric_mask});
                const auto indexed = _family_effect_binding_by_instance.find(instance_id);
                if (indexed != _family_effect_binding_by_instance.end())
                    publish_family_effect_metrics(
                        _family_effect_bindings[indexed->second],
                        family_effect_metric_revision(1),
                        MetricMask::all_declared(FAMILY_METRIC_COUNT));
            }
        }
        grant_random_pool_family_effect(family, submit_changes);
        if (!submit_changes) {
            const int32_t source_cell = family_influences().cell[branch];
            for (const std::string &key : _family_effect_keys) {
                EffectRuntime::FamilyEffectMetadataPod metadata;
                if (!_effect_runtime->family_effect_metadata_pod(key, metadata) ||
                    metadata.source_kind == 0)
                    continue;
                uint64_t base_target_handle = 0;
                uint32_t base_target_generation = 0;
                if (!resolve_effect_target(key, base_target_handle,
                        base_target_generation, metadata))
                    continue;
                const int32_t magnitude = family_effect_prestige_magnitude_q16(
                    family_effect_id_for_key(key), level);
                std::vector<int32_t> target_cells;
                collect_family_effect_target_cells(source_cell,
                    metadata.target_selector_kind, target_cells, key, level);
                if (target_cells.empty()) target_cells.push_back(source_cell);
                for (int32_t target_cell : target_cells) {
                    // The founding random-pool grant owns one instance per target
                    // cell under the shaped identity, so that is the first shape
                    // to probe. The branch-scope shape stays as the fallback for
                    // creators that do not mix the target cell
                    // (grant_ancestral_precept_for_country). Missing both is the
                    // original "the instance is gone" outcome.
                    int64_t instance_id = shaped_effect_instance_id(key, target_cell);
                    if (!instance_alive(instance_id)) {
                        instance_id = stable_effect_instance_id(key);
                        if (!instance_alive(instance_id)) continue;
                    }
                    uint64_t target_handle = base_target_handle;
                    uint32_t target_generation = base_target_generation;
                    // Same rule as the apply path above: a fan-out kind means
                    // one instance per cell, so the handle has to follow the
                    // cell rather than stay on the anchor.
                    if (metadata.target_selector_kind >=
                        EffectRuntime::SELECTOR_NEIGHBORS_R1) {
                        if (target_cell < 0 || target_cell >= _cell_count.get())
                            continue;
                        target_handle = static_cast<uint64_t>(target_cell);
                        target_generation = 1;
                    }
                    add_family_effect_binding({branch_handle, key, magnitude,
                        instance_id, branch_generation, metadata.target_domain,
                        target_handle, target_generation, metadata.metric_mask});
                }
            }
        }
    }
    for (const FamilyEffectBinding &binding : _family_effect_bindings) {
        if (binding.branch_handle != branch_handle) continue;
        add_effect_triggers(binding.definition_key);
    }
    for (size_t binding_row = 0; binding_row < _family_modifier_bindings.size(); ++binding_row) {
        auto binding_write = _family_modifier_bindings.edit_row(binding_row);
        FamilyModifierBinding &binding = binding_write[0];
        if (binding.branch_handle != branch_handle) continue;
        const auto found = desired.find(binding.definition_key);
        const int32_t magnitude = found == desired.end() ? 0 : found->second;
        if (submit_changes && _effect_runtime != nullptr &&
            magnitude != binding.magnitude_q16) {
            submit_effect_instance(binding.definition_key, magnitude);
        } else if (submit_changes && _modifier_runtime != nullptr &&
            magnitude != binding.magnitude_q16) {
            std::string error;
            _modifier_runtime->queue_family_group_effect(binding.definition_key,
                family_influences().cell[branch], static_cast<uint64_t>(
                    family_influences().stable_id[branch]), magnitude,
                _current_day.get(), error);
        }
        binding.magnitude_q16 = magnitude;
        if (found != desired.end()) desired.erase(found);
    }
    for (const auto &item : desired) {
        if (item.second == 0) continue;
        int32_t magnitude = item.second;
        if (!submit_changes && _modifier_runtime != nullptr) {
            const int32_t restored = _modifier_runtime->family_group_effect_magnitude(
                item.first, family_influences().cell[branch], static_cast<uint64_t>(
                    family_influences().stable_id[branch]));
            if (restored >= 0) magnitude = restored;
        } else if (submit_changes && _effect_runtime != nullptr) {
            submit_effect_instance(item.first, magnitude);
        } else if (_modifier_runtime != nullptr) {
            std::string error;
            _modifier_runtime->queue_family_group_effect(item.first,
                family_influences().cell[branch], static_cast<uint64_t>(
                    family_influences().stable_id[branch]), magnitude,
                _current_day.get(), error);
        }
        _family_modifier_bindings.push_back(
            {branch_handle, item.first, magnitude});
    }
    for (auto it = _family_trigger_bindings.begin();
         it != _family_trigger_bindings.end();) {
        if (it->branch_handle != branch_handle) {
            ++it;
            continue;
        }
        const auto found = desired_triggers.find(it->definition_key);
        if (found == desired_triggers.end()) {
            reconcile_trigger_branch_binding(_trigger_runtime,
                it->definition_key, branch_handle,
                family_influences().cell[branch], it->reward_target, false);
            it = _family_trigger_bindings.erase(it);
            continue;
        }
        if (found->second != it->reward_target &&
            reconcile_trigger_branch_binding(_trigger_runtime,
                it->definition_key, branch_handle,
                family_influences().cell[branch], found->second, true)) {
            auto binding_write = _family_trigger_bindings.edit_row(it - _family_trigger_bindings.begin());
            binding_write[0].reward_target = found->second;
        }
        desired_triggers.erase(found);
        ++it;
    }
    for (const auto &item : desired_triggers) {
        if (reconcile_trigger_branch_binding(_trigger_runtime, item.first,
                branch_handle, family_influences().cell[branch], item.second,
                true)) {
            _family_trigger_bindings.push_back(
                {branch_handle, item.first, item.second});
        }
    }
}

} // namespace pk

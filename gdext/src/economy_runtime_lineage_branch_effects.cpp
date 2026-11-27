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
#include "country_api.h"
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
    // A merchant post sells no good, so every receipt term of the normal
    // quote stays zero forever and the vacancy it leaves can never be ranked
    // as a mobility target -- which also keeps the type pinned on
    // INVESTMENT_REJECTION_ACTIVE_OWNER_VACANCY. Its owner quote is the
    // market retail pool share instead, priced against the seats this group
    // would add.
    if (is_merchant_service_post(type)) {
        const int64_t seats = std::max<int64_t>(1, saturating_mul(
            std::max<int64_t>(1, group.count),
            std::max<int64_t>(1, type.owner_slots_per_building), sat));
        const int64_t per_owner_day = merchant_retail_owner_income_per_day(
            group.cell, seats, seats, sat);
        quote.owner_income_per_day = per_owner_day;
        quote.disposable_survival_power_per_day = per_owner_day;
        quote.cash_receipt = saturating_mul(per_owner_day, seats, sat);
        quote.cash_revenue_per_day = quote.cash_receipt;
        quote.economic_revenue_per_day = quote.cash_receipt;
        quote.after_tax_revenue_per_day = quote.cash_receipt;
        quote.profit_per_day = per_owner_day;
        quote.utilization_q16 = Q16_ONE;
        quote.executable_capacity_q16 = Q16_ONE;
        quote.feasible = per_owner_day > 0;
        return quote;
    }
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
#include "economy_runtime_lineage_branch_effects_section_installed_capacity.inc"
#include "economy_runtime_lineage_branch_effects_section_owner_funding.inc"
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
        for (int32_t ni = 0; ni < type.output_count; ++ni) {
            const GoodAmount &natural_output = _building_outputs[
                type.output_begin + ni];
            const int64_t natural_base = effective_building_output_quantity(
                group, natural_output.good_id, natural_output.quantity,
                quote.natural_capacity_q16, std::max<int64_t>(1, group.count), sat);
            result.natural_max_output = saturating_add(
                result.natural_max_output,
                mul_div_sat(natural_base, soft_eff, Q16_ONE, sat),
                sat);
        }
        if (quote_trace) add_quote_section(quote_sections.fin_natural_ms, fin_natural_started);
        result.wages = mul_div_sat(wages_at_full_scale, activity_scale, Q16_ONE, sat);
        result.maintenance = mul_div_sat(
            maintenance_at_full_scale, activity_scale, Q16_ONE, sat);
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
            // Group-level daily quote: per-building recipe × installed count × soft bonus.
            const int64_t base_quantity = effective_building_output_quantity(
                group, output.good_id, output.quantity, activity_scale,
                std::max<int64_t>(1, group.count), sat);
            const int64_t quantity = mul_div_sat(
                base_quantity, soft_eff, Q16_ONE, sat);
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

#include "economy_runtime_lineage_branch_effects_section_reconciliation.inc"

} // namespace pk

#include "economy_runtime.h"
// Army pay's worker route drives the Country economy-asset peer synchronously
// (prepare -> service -> finish in one epoch), which needs the host's concrete
// type, exactly like economy_runtime.cpp.

#include <godot_cpp/variant/variant.hpp>
#include <algorithm>
#include <limits>

// Economy side of the army personnel lane.
// Contract: docs/plans/army-personnel-implementation-contract.md §1.
//
// Two rules from docs/cpp-dots-runtime/military-recruitment-pipeline.md decide
// the shape of this file:
//  1. Population is never written directly. A lane transfer only *queues* a
//     structural command; the cohort side of the move happens in
//     commit_structural_army_lane(), i.e. on the ordinary structural path that
//     keeps slot/page bookkeeping and the POD ledger shape valid.
//  2. The same command can reach the switch twice (POD plan plus the epoch
//     drain), so every opcode is deduplicated by `sequence` exactly like the
//     military cohort convert (opcode 24).

namespace pk {

// File-local Q16 one: the store is standalone and the runtime constants are
// nested, so both sides share this alias instead of repeating the literal.
constexpr int32_t kLaneQ16One = ArmyPersonnelStore::LANE_Q16_ONE;

// ───────────────────────── Guest consumption (§1.3) ──────────────────────────

void NativeEconomyRuntime::run_army_personnel_consumption(int32_t market, MarketResult &result) {
    if (_army_personnel.empty() || _army_personnel.size() <= 0) return;
    if (market < 0 || market >= market_store().market_count.get()) return;
    const int32_t cell_count = _cell_count.get();
    if (cell_count <= 0 ||
        market_store().cell_to_market.size() < static_cast<size_t>(cell_count))
        return;
    const int64_t epoch_days = std::max<int64_t>(1, _epoch_days.get());
    // Market cells are settled on worker threads; use a task-local saturation
    // counter instead of the shared member.
    int64_t sat = 0;
    const bool merchant_ok = market_has_living_merchant(market);
    thread_local std::vector<int32_t> merchants;
    merchants.clear();
    if (merchant_ok) collect_living_merchant_slots(market, merchants);
    if (merchants.empty()) {
        // No living merchant: the lane still records the shortfall below, but
        // there is nobody to pay, so no purchase happens at all.
    }
    const int32_t good_count = market_store().good_count.get();
    if (good_count <= 0) return;
    // Guest consumption removes market stock and pays merchants exactly like a
    // household does, so it must book both into the market result or the goods
    // and money audits fail (goods_conservation_failed at the first embark).
    int64_t lane_consumed = 0;
    int64_t lane_spent = 0;

    for (int32_t row = 0; row < _army_personnel.size(); ++row) {
        const size_t r = static_cast<size_t>(row);
        if (_army_personnel.active[r] == 0) continue;
        const int32_t cell = _army_personnel.cell[r];
        if (cell < 0 || cell >= cell_count) continue;
        if (market_store().cell_to_market[static_cast<size_t>(cell)] != market) continue;
        const int64_t people = std::max<int64_t>(0, _army_personnel.population[r]);
        if (people <= 0) continue;
        const int32_t profession = _army_personnel.profession_id[r];
        const int32_t plan_id = _army_personnel.plan_id[r];
        if (plan_id < 0 || plan_id >= static_cast<int32_t>(_plans.size())) continue;
        const Plan &plan = _plans[static_cast<size_t>(plan_id)];
        // Guest consumption happens only when the army sits on a cell its own
        // country still owns and there is a living merchant to buy from.
        // (Military owns the controller; Economy can only check ownership here.)
        const uint64_t lane_country = _army_personnel.country_handle[r];
        const int64_t cell_country = army_lane_country_handle(cell);
        const bool can_buy = merchant_ok && !merchants.empty() &&
            lane_country != 0 &&
            (cell_country == 0 || static_cast<uint64_t>(cell_country) == lane_country);
        int64_t funds_left = std::max<int64_t>(0, _army_personnel.funds[r]);
        const int64_t funds_before = funds_left;
        int64_t total_desired = 0;
        int64_t total_filled = 0;
        int64_t survival_desired = 0;
        int64_t survival_filled = 0;
        int64_t spent = 0;
        const int32_t ration_q16 = std::clamp<int32_t>(
            _army_personnel.ration_q16[r], 0, kLaneQ16One);
        for (int32_t n = 0; n < plan.need_count; ++n) {
            const int32_t need_index = plan.need_begin + n;
            if (need_index < 0 || need_index >= static_cast<int32_t>(_needs.size()))
                continue;
            const Need &need = _needs[static_cast<size_t>(need_index)];
            int64_t target = saturating_mul(
                saturating_mul(people, std::max<int64_t>(0, need.base_qty_per_person),
                               sat),
                epoch_days, sat);
            if (target <= 0) continue;
            const bool survival_need = need.stable_id >= 0 &&
                static_cast<size_t>(need.stable_id) < _survival_food_need_mask.size() &&
                _survival_food_need_mask[static_cast<size_t>(need.stable_id)] != 0;
            const bool survival_basket = survival_need ||
                (need.stable_id == _survival_clothing_need_stable_id);
            total_desired = saturating_add(total_desired, target, sat);
            if (survival_basket)
                survival_desired = saturating_add(survival_desired, target, sat);
            int64_t filled = 0;
            if (profession_need_is_state_supplied(profession, need.stable_id)) {
                // Ration needs are supplied in kind by Military: no market
                // purchase, the fill ratio is the army's published ration.
                filled = mul_div_sat(target, ration_q16, kLaneQ16One, sat);
            } else if (can_buy) {
                filled = 0;
                // First variant whose components are all in stock; its cost per
                // need unit decides how much of the target the lane can afford.
                for (int32_t v = 0; v < need.variant_count; ++v) {
                    const int32_t variant_id = need.variant_begin + v;
                    if (variant_id < 0 ||
                        variant_id >= static_cast<int32_t>(_variants.size()))
                        continue;
                    const VariantChoice &variant = _variants[static_cast<size_t>(variant_id)];
                    if (variant.component_count <= 0) continue;
                    int64_t unit_cash = 0;
                    int64_t stock_limit = std::numeric_limits<int64_t>::max();
                    bool usable = true;
                    for (int32_t c = 0; c < variant.component_count; ++c) {
                        const int32_t component_index = variant.component_begin + c;
                        if (component_index < 0 ||
                            component_index >= static_cast<int32_t>(_components.size())) {
                            usable = false;
                            break;
                        }
                        const NeedComponent &component =
                            _components[static_cast<size_t>(component_index)];
                        const int32_t good = component.good_id;
                        if (good < 0 || good >= good_count) {
                            usable = false;
                            break;
                        }
                        const int64_t index = market_store().index(market, good);
                        if (index < 0) {
                            usable = false;
                            break;
                        }
                        const int64_t stock = std::max<int64_t>(
                            0, market_store().stock[static_cast<size_t>(index)]);
                        const int64_t qty = std::max<int64_t>(1, component.qty_per_need);
                        const int64_t price = std::max<int64_t>(
                            0, market_store().price[static_cast<size_t>(index)]);
                        if (stock <= 0) {
                            usable = false;
                            break;
                        }
                        unit_cash = saturating_add(
                            unit_cash, mul_div_sat(qty, price, GOODS_SCALE,
                                                   sat),
                            sat);
                        stock_limit = std::min(
                            stock_limit,
                            mul_div_sat(stock, GOODS_SCALE, qty, sat));
                    }
                    if (!usable || unit_cash <= 0 || stock_limit <= 0) continue;
                    int64_t units = std::min(target, stock_limit);
                    if (funds_left > 0)
                        units = std::min(units, funds_left / unit_cash);
                    else
                        units = 0;
                    if (units <= 0) continue;
                    // Buy the goods, then charge exactly what was handed over.
                    int64_t cash = 0;
                    for (int32_t c = 0; c < variant.component_count; ++c) {
                        const NeedComponent &component =
                            _components[static_cast<size_t>(
                                variant.component_begin + c)];
                        const int64_t index = market_store().index(market, component.good_id);
                        const int64_t qty = std::max<int64_t>(1, component.qty_per_need);
                        int64_t bought = mul_div_sat(units, qty, GOODS_SCALE,
                                                     sat);
                        if (bought <= 0) bought = 1;
                        const int64_t stock = std::max<int64_t>(
                            0, market_store().stock[static_cast<size_t>(index)]);
                        bought = std::min(bought, stock);
                        if (bought <= 0) continue;
                        audit_touch_market_lane(static_cast<size_t>(index));
                        market_store().stock.write_scalar(
                            index, stock - bought, market_mutation_sink());
                        // The audit's goods expectation is
                        //   opening + explicit delta - consumed - ...
                        // and the incremental shadow already sees this stock
                        // drop (audit_touch_market_lane above), so the removed
                        // units MUST be booked as consumed here or the closing
                        // balance can never equal the expectation
                        // (goods_conservation_failed on the first embark).
                        lane_consumed = saturating_add(lane_consumed, bought, sat);
                        cash = saturating_add(cash, mul_div_sat(
                            bought, std::max<int64_t>(
                                0, market_store().price[static_cast<size_t>(index)]),
                            GOODS_SCALE, sat), sat);
                    }
                    cash = std::min(cash, funds_left);
                    if (cash <= 0) break;
                    funds_left -= cash;
                    spent = saturating_add(spent, cash, sat);
                    filled = units;
                    break;
                }
            }
            filled = std::clamp<int64_t>(filled, 0, target);
            total_filled = saturating_add(total_filled, filled, sat);
            if (survival_basket)
                survival_filled = saturating_add(survival_filled, filled,
                                                 sat);
        }
        // Pay the merchant population proportionally, exactly like the household
        // clearing revenue split. Money is transferred, never minted.
        if (spent > 0 && !merchants.empty()) {
            int64_t merchant_population = 0;
            for (const int32_t slot : merchants)
                merchant_population = saturating_add(
                    merchant_population, std::max<int64_t>(0,
                        population_store().population[slot]), sat);
            if (merchant_population > 0) {
                int64_t prefix = 0;
                int64_t distributed = 0;
                for (const int32_t slot : merchants) {
                    prefix = saturating_add(prefix, std::max<int64_t>(0,
                        population_store().population[slot]), sat);
                    const int64_t next = mul_div_sat(spent, prefix, merchant_population,
                                                     sat);
                    const int64_t share = std::max<int64_t>(0, next - distributed);
                    distributed = next;
                    if (share <= 0) continue;
                    population_store().funds.write_scalar(
                        slot, saturating_add(population_store().funds[slot], share,
                                             sat),
                        market_mutation_sink());
                    population_store().epoch_income.write_scalar(
                        slot, saturating_add(population_store().epoch_income[slot], share,
                                             sat),
                        market_mutation_sink());
                }
                if (distributed < spent) {
                    // Rounding remainder to the first merchant so the transfer
                    // stays exactly equal to the lane's debit.
                    const int32_t slot = merchants.front();
                    population_store().funds.write_scalar(
                        slot, saturating_add(population_store().funds[slot],
                                             spent - distributed, sat),
                        market_mutation_sink());
                    population_store().epoch_income.write_scalar(
                        slot, saturating_add(population_store().epoch_income[slot],
                                             spent - distributed, sat),
                        market_mutation_sink());
                }
            } else {
                // No merchant population to pay: undo the spending by not
                // charging it. Stock was already taken, so give the money back
                // to the lane (conservation beats realism here).
                spent = 0;
            }
        }
        if (spent == 0 && funds_left != funds_before) funds_left = funds_before;
        _army_personnel.funds[r] = funds_left;
        _army_personnel.epoch_expense[r] = saturating_add(
            _army_personnel.epoch_expense[r], spent, sat);
        _army_personnel.satisfaction_q16[r] = total_desired > 0
            ? static_cast<int32_t>(std::clamp<int64_t>(
                  mul_div_sat(total_filled, kLaneQ16One, total_desired, sat),
                  0, kLaneQ16One - 1))
            : kLaneQ16One - 1;
        lane_spent = saturating_add(lane_spent, spent, sat);
        _army_personnel.survival_q16[r] = survival_desired > 0
            ? static_cast<int32_t>(std::clamp<int64_t>(
                  mul_div_sat(survival_filled, kLaneQ16One, survival_desired,
                              sat),
                  0, kLaneQ16One - 1))
            : _army_personnel.satisfaction_q16[r];
    }
    result.consumed_goods = saturating_add(result.consumed_goods, lane_consumed, sat);
    result.revenue = saturating_add(result.revenue, lane_spent, sat);
}

} // namespace pk

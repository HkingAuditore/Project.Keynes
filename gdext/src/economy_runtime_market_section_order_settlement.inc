    result.formula_ms += elapsed_ms(formula_start);

    thread_local std::vector<int32_t> budget_tax_rates;
    if (consumption_tax_active) budget_tax_rates.resize(std::max<size_t>(1, _components.size()));
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
                0, population_store().funds[slots[local]] -
                    cohort_working_capital_reserve[local] -
                    (use_remaining ? cohort_spend[local] : 0) -
                    budget_committed[local]);
            GoodsBill desired_bill;
            for (size_t i = begin; i < end; ++i)
                desired_bill.add(orders[i].desired_units, orders[i].unit_price, sat);
            // One independently rounded base per fiscal policy can cost more
            // than the aggregate linear quote. Reserve that bounded difference
            // before allocating quantities, never repair it by clipping payment.
            int64_t rounding_reserve = 0;
            if (consumption_tax_active) {
                size_t policies = 0;
                for (size_t i = begin; i < end; ++i) {
                    if (orders[i].desired_units <= 0) continue;
                    const VariantChoice &variant = _variants[orders[i].variant_index];
                    for (int32_t c = 0; c < variant.component_count; ++c) {
                        const int32_t rate = frozen_tax_rate(cohort_cell(orders[i].slot),
                            CountryApi::TAX_CONSUMPTION,
                            _components[variant.component_begin + c].good_id);
                        size_t policy = 0;
                        while (policy < policies && budget_tax_rates[policy] != rate) ++policy;
                        if (policy == policies) {
                            budget_tax_rates[policies++] = rate;
                            if (rate > 0) rounding_reserve += (rate + 9999) / 10000;
                        }
                    }
                }
                rounding_reserve += std::max<int64_t>(0, static_cast<int64_t>(policies) - 1);
            }
            // A quoted discount is floored per desired unit, while settlement
            // recomputes it from the component base actually delivered. Reserve
            // that sub-unit difference instead of discovering it as an invoice
            // the cohort cannot cover.
            if (subsidy_settlement) {
                for (size_t i = begin; i < end; ++i) {
                    if (orders[i].quoted_subsidy_per_unit > 0 &&
                        orders[i].desired_units > 0) ++rounding_reserve;
                }
            }
            remaining = std::max<int64_t>(0, remaining - rounding_reserve);
            const int64_t total_cost = desired_bill.total(sat);
            if (total_cost <= remaining) {
                for (size_t i = begin; i < end; ++i) orders[i].funded_units = orders[i].desired_units;
            } else if (remaining > 0 && total_cost > 0) {
                GoodsBill prefix_bill;
                int64_t cost_prefix = 0;
                int64_t allocated_cost = 0;
                for (size_t i = begin; i < end; ++i) {
                    prefix_bill.add(orders[i].desired_units, orders[i].unit_price, sat);
                    cost_prefix = prefix_bill.total(sat);
                    const int64_t next = mul_div_sat(cost_prefix, remaining, total_cost, sat);
                    const int64_t share = std::max<int64_t>(0, next - allocated_cost);
                    allocated_cost = next;
                    orders[i].funded_units = orders[i].unit_price <= 0
                        ? orders[i].desired_units
                        : std::min(orders[i].desired_units,
                            mul_div_sat(share, GOODS_SCALE,
                                        orders[i].unit_price, sat));
                }
            }
            GoodsBill committed_bill;
            for (size_t i = begin; i < end; ++i)
                committed_bill.add(orders[i].funded_units, orders[i].unit_price, sat);
            const int64_t committed = saturating_add(
                committed_bill.total(sat), rounding_reserve, sat);
            budget_committed[local] = saturating_add(
                budget_committed[local], committed, sat);
            begin = end;
        }
    };

    struct HouseholdBillBucket { int32_t rate = 0; GoodsBill bill; };
    thread_local std::vector<HouseholdBillBucket> settlement_bills;
    settlement_bills.resize(std::max<size_t>(1, _components.size()));
    size_t settlement_bill_count = 0;
    int32_t billing_local = -1, billing_priority = -1;
    const auto record_order_settlement = [&](BundleOrder &order) {
        if (order.filled_units <= 0) return;
        if (billing_local != order.local_cohort || billing_priority != order.priority) {
            billing_local = order.local_cohort;
            billing_priority = order.priority;
            settlement_bill_count = 0;
        }
        const int32_t cell = cohort_cell(order.slot);
        const VariantChoice &variant = _variants[order.variant_index];
        int64_t food_eq = 0, base_spend = 0, positive_tax = 0, subsidy = 0;
        for (int32_t c = 0; c < variant.component_count; ++c) {
            const NeedComponent &component = _components[variant.component_begin + c];
            const int64_t quantity = mul_div_sat(order.filled_units,
                component_quantity(order.slot, component), GOODS_SCALE, sat);
            food_eq = saturating_add(food_eq,
                food_equivalent(component.good_id, quantity), sat);
            const int32_t rate = consumption_tax_active ? frozen_tax_rate(
                cell, CountryApi::TAX_CONSUMPTION, component.good_id) : 0;
            size_t bucket = 0;
            while (bucket < settlement_bill_count && settlement_bills[bucket].rate != rate)
                ++bucket;
            if (bucket == settlement_bill_count) {
                settlement_bills[bucket] = {rate, {}};
                ++settlement_bill_count;
            }
            const int64_t component_base = settlement_bills[bucket].bill.add(quantity,
                market_store().price[market_store().index(market, component.good_id)], sat);
            base_spend = saturating_add(base_spend, component_base, sat);
            const int64_t price = market_store().price[market_store().index(market, component.good_id)];
            if (component_base > 0 && quantity > 0 && quantity < GOODS_SCALE &&
                price < GOODS_SCALE && quantity * price < GOODS_SCALE)
                ++result.small_payment_roundups;
            if (consumption_tax_active) {
                const int32_t mode = frozen_tax_mode(
                    cell, CountryApi::TAX_CONSUMPTION,
                    component.good_id);
                const int64_t tax_base =
                    mode == CountryApi::TAX_MODE_ABSOLUTE
                        ? quantity
                        : component_base;
                const int64_t transfer = apply_fiscal_tax(
                    cell, CountryApi::TAX_CONSUMPTION, tax_base,
                    rate, mode, sat);
                if (transfer > 0) positive_tax = saturating_add(positive_tax, transfer, sat);
                else subsidy = saturating_add(subsidy, -transfer, sat);
            }
        }
        result.food_access_eq = saturating_add(result.food_access_eq, food_eq, sat);
        if (food_eq > 0) ++result.food_access_events;
        record_food_access(cell, food_eq);
        const int32_t pay = family_purchase_pay_factor_q16(order.slot);
        if (pay < Q16_ONE && base_spend > 0) {
            const int64_t request = mul_div_sat(base_spend, Q16_ONE - pay, Q16_ONE, sat);
            subsidy = saturating_add(subsidy, -apply_fiscal_tax(cell,
                CountryApi::TAX_CONSUMPTION, request, -10000, sat), sat);
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
        if (order.need_index >= 0 && order.need_index < static_cast<int32_t>(need_states.size()))
            need_states[order.need_index].spent_money = saturating_add(
                need_states[order.need_index].spent_money, net_spend, sat);
    };
    auto clear_orders = [&](std::vector<BundleOrder> &orders,
                            bool count_physical_shortage) -> bool {
        billing_local = -1;
        settlement_bill_count = 0;
        good_counts.assign(market_store().good_count.get(), 0);
        pass_demand.assign(market_store().good_count.get(), 0);
        for (const BundleOrder &order : orders) {
            const VariantChoice &variant = _variants[order.variant_index];
            for (int32_t c = 0; c < variant.component_count; ++c) {
                const NeedComponent &component = _components[variant.component_begin + c];
                if (count_physical_shortage && order.desired_units > 0) {
                    const int64_t desired_required = mul_div_sat(
                        order.desired_units,
                        component_quantity(order.slot, component), GOODS_SCALE, sat);
                    good_desired_demand[component.good_id] = saturating_add(
                        good_desired_demand[component.good_id], desired_required, sat);
                }
                if (order.funded_units <= 0) continue;
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
        if (count_physical_shortage) {
            for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
                const int64_t idx = market_store().index(market, good);
                const int64_t available = std::max<int64_t>(0,
                    market_store().stock[idx] - production_input_floor[good]);
                good_stock_shortfall[good] = saturating_add(
                    good_stock_shortfall[good],
                    saturating_sub(good_desired_demand[good], available, sat), sat);
            }
        }
        bool abundant = true;
        for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
            abundant &= std::max<int64_t>(0,
                market_store().stock[market_store().index(market, good)] -
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
            for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
                const int64_t idx = market_store().index(market, good);
                audit_touch_market_lane(static_cast<size_t>(idx));
                market_store().stock.write_scalar(idx, market_store().stock[idx] - (pass_demand[good]), market_mutation_sink());
                good_sales[good] = saturating_add(good_sales[good], pass_demand[good], sat);
                result.consumed_goods = saturating_add(result.consumed_goods,
                                                       pass_demand[good], sat);
                if (good < static_cast<int32_t>(_good_storage_modes.size()) &&
                    _good_storage_modes[good] == 1)
                    result.cycle_flow_consumed = saturating_add(
                        result.cycle_flow_consumed, pass_demand[good], sat);
            }
            return true;
        }
        good_offsets.assign(market_store().good_count.get() + 1, 0);
        good_cursor.assign(market_store().good_count.get(), 0);
        for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
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
        for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
            int64_t total = 0;
            for (int32_t k = good_offsets[good]; k < good_offsets[good + 1]; ++k) {
                total = saturating_add(total, component_refs[k].required_qty, sat);
            }
            const int64_t available = std::min<int64_t>(
                std::max<int64_t>(0, market_store().stock[market_store().index(market, good)] -
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
        pass_sales.assign(market_store().good_count.get(), 0);
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
        for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
            const int64_t idx = market_store().index(market, good);
            const int64_t used = std::min(pass_sales[good], market_store().stock[idx]);
            audit_touch_market_lane(static_cast<size_t>(idx));
            market_store().stock.write_scalar(idx, market_store().stock[idx] - (used), market_mutation_sink());
            good_sales[good] = saturating_add(good_sales[good], used, sat);
            result.consumed_goods = saturating_add(result.consumed_goods, used, sat);
            if (good < static_cast<int32_t>(_good_storage_modes.size()) &&
                _good_storage_modes[good] == 1)
                result.cycle_flow_consumed = saturating_add(
                    result.cycle_flow_consumed, used, sat);
        }
        return false;
    };

    const auto clear_start = Clock::now();
    apply_subsidy_quotes(primary_orders);
    budget_orders(primary_orders, false);
    const bool primary_inventory_abundant = clear_orders(primary_orders, true);
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
                available &= market_store().stock[market_store().index(market, component.good_id)] >
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
                available &= market_store().stock[market_store().index(market, component.good_id)] >
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

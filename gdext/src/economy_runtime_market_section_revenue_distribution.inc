        budget_orders(fallback_orders, true);
        clear_orders(fallback_orders, false);
    }

    for (int32_t slot : slots) {
        auto entry = std::lower_bound(
            _owner_retained_outputs.begin(), _owner_retained_outputs.end(), slot,
            [](const OwnerRetainedOutput &value, int32_t owner_slot) {
                return value.owner_slot < owner_slot;
            });
        while (entry != _owner_retained_outputs.end() && entry->owner_slot == slot) {
            // Any owner-plan quantity left after actual household use is the
            // final remainder of the same production chain.  Settle it through
            // producer support immediately; do not create a second inventory
            // path or defer the producer receipt to the next cycle.
            bool supported_remainder = false;
            if (entry->quantity > 0 && entry->owner_slot >= 0 &&
                entry->owner_slot < static_cast<int32_t>(population_store().active.size())) {
                const int32_t page = entry->owner_slot / COHORT_PAGE_SIZE;
                if (page >= 0 && page < static_cast<int32_t>(population_store().page_cell.size())) {
                    const int32_t cell = population_store().page_cell[page];
                    if (cell >= 0 && cell < static_cast<int32_t>(market_store().cell_to_market.size())) {
                        const int32_t market = market_store().cell_to_market[cell];
                        if (market >= 0 && market < market_store().market_count.get() &&
                            entry->good_id >= 0 && entry->good_id < market_store().good_count.get()) {
                            const int64_t issue_value =
                                _good_monetary_issue_values[entry->good_id];
                            const int64_t market_price = market_store().price[
                                market_store().index(market, entry->good_id)];
                            // Market prices are native currency-per-GOODS_SCALE
                            // units.  Apply the documented one-fifth support
                            // price without introducing a Q16 scale factor.
                            const int64_t support_unit_value = issue_value > 0
                                ? issue_value
                                : mul_div_sat(market_price, 1, 5, sat);
                            const int64_t support_paid = mul_div_sat(
                                entry->quantity, support_unit_value, GOODS_SCALE, sat);
                            const int64_t stock_index = market_store().index(
                                market, entry->good_id);
                            audit_touch_market_lane(static_cast<size_t>(stock_index));
                            market_store().stock.write_scalar(stock_index, saturating_add(
                                market_store().stock[stock_index], entry->quantity, sat), market_mutation_sink());
                            touch_accounting_slot(entry->owner_slot);
                            population_store().funds.write_scalar(entry->owner_slot, saturating_add(
                                population_store().funds[entry->owner_slot],
                                support_paid, sat), market_mutation_sink());
                            population_store().epoch_income.write_scalar(entry->owner_slot, saturating_add(
                                population_store().epoch_income[entry->owner_slot],
                                support_paid, sat), market_mutation_sink());
                            trace_record_cashflow(cell,
                                population_store().handle_for_slot(entry->owner_slot),
                                CASHFLOW_PRODUCER_SUPPORT, support_paid, 0);
                            if (entry->building_group >= 0 &&
                                entry->building_group < static_cast<int32_t>(building_count())) {
                                buildings_store().last_producer_support_receipt.write_scalar(
                                    entry->building_group, saturating_add(
                                    buildings_store().last_producer_support_receipt[
                                        entry->building_group], support_paid, sat));
                                if (issue_value > 0)
                                    buildings_store().last_bullion_mint_receipt.write_scalar(
                                        entry->building_group, saturating_add(
                                        buildings_store().last_bullion_mint_receipt[
                                            entry->building_group], support_paid, sat));
                            }
                            result.supported_output = saturating_add(
                                result.supported_output, entry->quantity, sat);
                            if (_good_storage_modes[entry->good_id] == 1) {
                                result.supported_cycle_flow_output = saturating_add(
                                    result.supported_cycle_flow_output, entry->quantity, sat);
                            }
                            result.supported_money = saturating_add(
                                result.supported_money, support_paid, sat);
                            if (issue_value > 0) {
                                result.bullion_money = saturating_add(
                                    result.bullion_money, support_paid, sat);
                                result.bullion_stock = saturating_add(
                                    result.bullion_stock, entry->quantity, sat);
                                market_store().stock.write_scalar(stock_index, saturating_sub(
                                    market_store().stock[stock_index], entry->quantity, sat), market_mutation_sink());
                                if (_good_ids[entry->good_id] == "gold") {
                                    result.gold_accepted = saturating_add(
                                        result.gold_accepted, entry->quantity, sat);
                                    result.gold_money = saturating_add(
                                        result.gold_money, support_paid, sat);
                                } else {
                                    result.silver_accepted = saturating_add(
                                        result.silver_accepted, entry->quantity, sat);
                                    result.silver_money = saturating_add(
                                        result.silver_money, support_paid, sat);
                                }
                            }
                            supported_remainder = true;
                        }
                    }
                }
            }
            if (!supported_remainder) {
                // Keep the existing safety fallback for malformed/stale owner
                // handles so invalid records cannot leave goods unaccounted for.
                result.retained_output_discarded = saturating_add(
                    result.retained_output_discarded, entry->quantity, sat);
                if (entry->quantity > 0 && entry->building_group >= 0 &&
                    entry->building_group < static_cast<int32_t>(building_count())) {
                    buildings_store().last_discarded.write_scalar(entry->building_group, saturating_add(
                        buildings_store().last_discarded[entry->building_group],
                        entry->quantity, sat));
                }
            }
            entry->quantity = 0;
            ++entry;
        }
    }
    // Cycle-flow goods are services within this settlement. Unsold shelf
    // remainder expires after both retail and retained-output reconciliation.
    for (int32_t good = 0; good < market_store().good_count.get(); ++good) {
        if (_good_storage_modes[good] != 1) continue;
        const int32_t index = market_store().index(market, good);
        const int64_t remainder = std::max<int64_t>(0, market_store().stock[index]);
        if (remainder <= 0) continue;
        audit_touch_market_lane(static_cast<size_t>(index));
        market_store().stock.write_scalar(index, 0, market_mutation_sink());
        result.cycle_flow_discarded = saturating_add(
            result.cycle_flow_discarded, remainder, sat);
    }
    result.fallback_ms += elapsed_ms(fallback_start);

    const auto merchant_start = Clock::now();
    for (int32_t local = 0; local < cohort_count; ++local) {
        if (cohort_spend[local] > std::max<int64_t>(0,
                population_store().funds[slots[local]] - cohort_working_capital_reserve[local])) {
            error = "household_invoice_exceeds_reserved_cash";
            return false;
        }
    }
    int64_t planned_revenue = 0;
    for (int32_t local = 0; local < cohort_count; ++local) {
        const int32_t slot = slots[local];
        const int64_t spend = std::min(cohort_spend[local], std::max<int64_t>(
            0, population_store().funds[slot] - cohort_working_capital_reserve[local]));
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
        const int64_t quoted_spend = cohort_spend[local];
        const int64_t spend = quoted_spend > 0
            ? std::min(quoted_spend, std::max<int64_t>(
                0, population_store().funds[slot] -
                    cohort_working_capital_reserve[local]))
            : quoted_spend;
        const int64_t cash_outlay = std::max<int64_t>(0, spend);
        const int64_t cash_income = std::max<int64_t>(0, -spend);
        population_store().funds.write_scalar(slot, saturating_add(
            population_store().funds[slot] - cash_outlay, cash_income, sat), market_mutation_sink());
        population_store().epoch_expense.write_scalar(slot, saturating_add(
            population_store().epoch_expense[slot], cash_outlay, sat), market_mutation_sink());
        population_store().epoch_income.write_scalar(slot, saturating_add(
            population_store().epoch_income[slot], cash_income, sat), market_mutation_sink());
        const int64_t subsidy = cohort_consumption_subsidy[local];
        record_cohort_fiscal(slot, cohort_consumption_tax[local]);
        record_cohort_fiscal(slot, -subsidy);
        if (trace_detail && cash_outlay > 0) {
            result.cashflows.push_back({population_store().handle_for_slot(slot),
                CASHFLOW_HOUSEHOLD_CONSUMPTION, 0, cash_outlay});
        }
        if (trace_detail && cohort_consumption_tax[local] > 0)
            result.cashflows.push_back({population_store().handle_for_slot(slot),
                CASHFLOW_CONSUMPTION_TAX, 0,
                cohort_consumption_tax[local]});
        if (trace_detail && subsidy > 0)
            result.cashflows.push_back({population_store().handle_for_slot(slot),
                CASHFLOW_CONSUMPTION_SUBSIDY, subsidy, 0});
        revenue = saturating_add(revenue,
            consumption_tax_active || subsidy_settlement ? cohort_base_spend[local] : spend, sat);
    }
    int64_t merchant_population = 0;
    for (const int32_t slot : living_merchants) {
        merchant_population = saturating_add(merchant_population,
            population_store().population[slot], sat);
    }
    result.merchant_population = merchant_population;
    if (revenue > 0 && merchant_population <= 0) {
        error = "market_revenue_has_no_merchant_owner";
        return false;
    }
    int64_t population_prefix = 0;
    int64_t distributed = 0;
    for (const int32_t slot : living_merchants) {
        population_prefix = saturating_add(population_prefix, population_store().population[slot], sat);
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
                0, population_store().epoch_expense[slot] - household_expense);
            const int64_t taxable_income =
                std::max<int64_t>(0, share - operating_expense);
            const int32_t signature = static_cast<int32_t>(
                population_store().signature_id[slot]);
            const int32_t profession = signature >= 0 &&
                    signature < static_cast<int32_t>(_signatures.size())
                ? _signatures[signature].profession_id : -1;
            const int32_t cell = cohort_cell(slot);
            const int32_t income_rate = frozen_tax_rate(
                cell, CountryApi::TAX_INCOME, profession);
            const int32_t income_mode = frozen_tax_mode(
                cell, CountryApi::TAX_INCOME, profession);
            if (income_mode == CountryApi::TAX_MODE_ABSOLUTE) {
                // Absolute income levies settle in
                // settle_absolute_daily_taxes_for_cell.
            } else if (income_rate < 0) {
                if (slot >= 0 && slot < static_cast<int32_t>(
                        _income_taxable_base_by_slot.size())) {
                    _income_taxable_base_by_slot[slot] = saturating_add(
                        _income_taxable_base_by_slot[slot], taxable_income,
                        sat);
                }
            } else {
                income_tax = apply_fiscal_tax(
                    cell, CountryApi::TAX_INCOME, taxable_income,
                    income_rate, income_mode, sat);
                record_cohort_fiscal(slot, income_tax);
            }
        }
        const int64_t net_share = saturating_sub(share, income_tax, sat);
        // Merchant household income is real cash booked to the cohort, never
        // to a building. Record the market total so the merchant post
        // projection can attribute a share of it to an owner seat.
        result.merchant_household_retail = saturating_add(
            result.merchant_household_retail, net_share, sat);
        population_store().funds.write_scalar(slot, saturating_add(
            population_store().funds[slot], net_share, sat), market_mutation_sink());
        population_store().epoch_income.write_scalar(slot, saturating_add(
            population_store().epoch_income[slot], share, sat), market_mutation_sink());
        if (trace_detail && share > 0) {
            result.cashflows.push_back({population_store().handle_for_slot(slot),
                CASHFLOW_MERCHANT_HOUSEHOLD, share, 0});
        }
        if (trace_detail && income_tax > 0)
            result.cashflows.push_back({population_store().handle_for_slot(slot),
                CASHFLOW_INCOME_TAX, 0, income_tax});
        else if (trace_detail && income_tax < 0)
            result.cashflows.push_back({population_store().handle_for_slot(slot),
                CASHFLOW_INCOME_SUBSIDY, -income_tax, 0});
    }
    result.merchant_count += static_cast<int64_t>(living_merchants.size());
    result.revenue = revenue;
    cohort_worst_q16.assign(cohort_count, Q16_ONE - 1);
    cohort_worst_need.assign(cohort_count, std::numeric_limits<uint16_t>::max());

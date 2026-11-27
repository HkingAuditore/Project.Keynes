    thread_local std::vector<int64_t> maintenance_observed;
    maintenance_observed.assign(cell_signal_count, 0);
    thread_local std::vector<std::pair<int32_t, int64_t>> ceiling_maintenance_wallets;
    ceiling_maintenance_wallets.clear();
    if (observe_price_ceiling) ceiling_maintenance_wallets.reserve(end - begin);
    for (int32_t g = begin; g < end; ++g) {
        {
            const auto view = building_view(static_cast<size_t>(g));
            if (view.cell != cell || view.count <= 0 ||
                view.operating_state == 1 ||
                !building_available(cell, view.type_id, true) ||
                _building_types[view.type_id].maintenance_count <= 0) continue;
            // Military state lots (kind 3) are maintained by the MILITARY runtime
            // as a physical repair purchase (design §1 / plan S4-5). Their upkeep
            // is settled from the military budget against repair materials, so the
            // generic private-building maintenance must never buy for them too:
            // that would be two buyers and two consumers for one building. The
            // catalog already forbids `maintenance_*` on state kinds
            // (economy_catalog.gd), so this is the explicit second line of
            // defence - a catalog edit must not silently create a double bill.
            if (_building_types[view.type_id].kind == 3) continue;
        }
        auto group = building_at(static_cast<size_t>(g));
        const BuildingType &type = _building_types[group.type_id];
        const int64_t maintenance_daily = daily_maintenance_cost_for_type(
            cell, type, _saturation_count);
        if (maintenance_daily != std::numeric_limits<int64_t>::max())
            group.last_maintenance_due = saturating_mul(
                saturating_mul(std::max<int64_t>(0, maintenance_daily),
                    group.count, _saturation_count),
                std::max(1, _epoch_days.get()), _saturation_count);
        const int32_t owner_slot = find_cohort_slot(cell, group.owner_signature_id);
        if (owner_slot < 0) continue;
        const int64_t building_days = saturating_mul(
            group.count, std::max(1, _epoch_days.get()), _saturation_count);
        int64_t paid = 0;
        GoodsBill maintenance_bill;
        const bool merchants_present = local_merchants_can_receive(cell);
        for (int32_t i = 0; i < type.maintenance_count; ++i) {
            const GoodAmount &item =
                _building_maintenance_goods[type.maintenance_begin + i];
            if (!is_storable_nonmonetary_good(item.good_id)) continue;
            const int64_t desired = saturating_mul(
                building_days, item.quantity, _saturation_count);
            const int32_t signal = market_signal_index(cell, item.good_id);
            if (signal >= 0 && signal < static_cast<int32_t>(
                    _epoch_desired_business_demand.size())) {
                _epoch_desired_business_demand[signal] = saturating_add(
                    _epoch_desired_business_demand[signal], desired,
                    _saturation_count);
            }
            const int64_t price = maintenance_settlement_price(
                cell, item.good_id, _saturation_count);
            const int64_t stock_index = market_store().index(market, item.good_id);
            const int64_t stock = merchants_present
                ? std::max<int64_t>(0, market_store().stock[stock_index]) : 0;
            const int64_t affordable = price > 0
                ? mul_div_sat(std::max<int64_t>(0, population_store().funds[owner_slot]),
                              GOODS_SCALE, price, _saturation_count)
                : 0;
            const int64_t bought = std::min(desired, std::min(stock, affordable));
            if (observe_price_ceiling && signal >= 0 &&
                signal < static_cast<int32_t>(_epoch_ceiling_business_requested.size())) {
                auto wallet = std::find_if(ceiling_maintenance_wallets.begin(),
                    ceiling_maintenance_wallets.end(), [owner_slot](const auto &entry) {
                        return entry.first == owner_slot;
                    });
                if (wallet == ceiling_maintenance_wallets.end()) {
                    ceiling_maintenance_wallets.push_back({owner_slot,
                        std::max<int64_t>(0, population_store().funds[owner_slot])});
                    wallet = ceiling_maintenance_wallets.end() - 1;
                }
                wallet->second = std::min(wallet->second,
                    std::max<int64_t>(0, population_store().funds[owner_slot]));
                const int64_t requested = price > 0 ? std::min(desired,
                    mul_div_sat(wallet->second, GOODS_SCALE, price, _saturation_count)) : 0;
                wallet->second -= goods_cost(requested, price, _saturation_count);
                _epoch_ceiling_business_requested[signal] = saturating_add(
                    _epoch_ceiling_business_requested[signal], requested, _saturation_count);
                _epoch_ceiling_business_unfilled[signal] = saturating_add(
                    _epoch_ceiling_business_unfilled[signal], std::max<int64_t>(0, requested - bought), _saturation_count);
            }
            const int64_t unmet = std::max<int64_t>(0, desired - bought);
            _maintenance_unmet = saturating_add(
                _maintenance_unmet, unmet, _saturation_count);
            if (unmet > 0 && price > 0) {
                _maintenance_unpaid_value = saturating_add(
                    _maintenance_unpaid_value,
                    mul_div_sat(unmet, price, GOODS_SCALE, _saturation_count),
                    _saturation_count);
            }
            if (bought <= 0 || price <= 0) continue;
            const int64_t cost = maintenance_bill.add(bought, price, _saturation_count);
            if (cost > population_store().funds[owner_slot]) continue;
            audit_touch_market_lane(static_cast<size_t>(stock_index));
            market_store().stock.write_scalar(stock_index, market_store().stock[stock_index] - (bought), market_mutation_sink());
            population_store().funds.write_scalar(owner_slot, population_store().funds[owner_slot] - (cost), market_mutation_sink());
            population_store().epoch_expense.write_scalar(owner_slot, saturating_add(
                population_store().epoch_expense[owner_slot], cost, _saturation_count), market_mutation_sink());
            paid = saturating_add(paid, cost, _saturation_count);
            _maintenance_goods_consumed = saturating_add(
                _maintenance_goods_consumed, bought, _saturation_count);
            if (signal >= 0 && signal < static_cast<int32_t>(
                    _epoch_nonhousehold_withdrawals.size())) {
                _epoch_nonhousehold_withdrawals[signal] = saturating_add(
                    _epoch_nonhousehold_withdrawals[signal], bought,
                    _saturation_count);
            }
            if (signal >= 0 && signal < static_cast<int32_t>(
                    _epoch_funded_business_demand.size())) {
                _epoch_funded_business_demand[signal] = saturating_add(
                    _epoch_funded_business_demand[signal], bought,
                    _saturation_count);
            }
            if (signal >= cell_signal_begin && signal < cell_signal_end) {
                const size_t local = static_cast<size_t>(signal - cell_signal_begin);
                maintenance_observed[local] = saturating_add(
                    maintenance_observed[local], bought, _saturation_count);
            }
            trace_record_cashflow(cell, population_store().handle_for_slot(owner_slot),
                                  CASHFLOW_PRODUCTION_INPUT, 0, cost);
            if (credit_local_merchants(cell, cost,
                                       CASHFLOW_MERCHANT_BUSINESS,
                                       &_saturation_count) != cost) {
                error = "building_maintenance_has_no_merchant_owner";
                return false;
            }
        }
        group.last_maintenance_cost = paid;
        group.last_operating_cost = saturating_add(
            group.last_operating_cost, paid, _saturation_count);
    }
    // Negative business tax is a cost reimbursement. Inputs use untaxed base
    // value; only actually paid base wages and maintenance qualify. Bonuses,
    // owner livelihood, debt service, construction and taxes are excluded.
    if (business_tax_active) {
        for (int32_t g = begin; g < end; ++g) {
            const auto group = building_view(static_cast<size_t>(g));
            const int32_t rate = frozen_tax_rate(
                cell, CountryApi::TAX_BUSINESS, group.type_id);
            const int32_t mode = frozen_tax_mode(
                cell, CountryApi::TAX_BUSINESS, group.type_id);
            // Absolute business subsidies settle once per building-day in
            // settle_absolute_daily_taxes_for_cell. Never reinterpret the
            // absolute currency amount as a percent-of-cost basis point.
            if (rate >= 0 ||
                mode == CountryApi::TAX_MODE_ABSOLUTE ||
                group.owner_signature_id < 0) continue;
            const int32_t owner_slot = find_cohort_slot(
                cell, group.owner_signature_id);
            if (owner_slot < 0) continue;
            const int64_t eligible_cost = saturating_add(
                saturating_add(group.last_input_cost,
                               group.last_base_wages_paid,
                               _saturation_count),
                group.last_maintenance_cost, _saturation_count);
            const int64_t transfer = apply_fiscal_tax(
                cell, CountryApi::TAX_BUSINESS, eligible_cost,
                rate, mode, _saturation_count);
            if (transfer >= 0) continue;
            const int64_t subsidy = -transfer;
            buildings_store().last_business_subsidy_received.write_scalar(g,
                saturating_add(group.last_business_subsidy_received, subsidy,
                    _saturation_count), market_mutation_sink());
            business_transfer_by_group[g - begin] = saturating_add(
                business_transfer_by_group[g - begin], transfer,
                _saturation_count);
            touch_accounting_slot(owner_slot);
            population_store().funds.write_scalar(owner_slot, saturating_add(
                population_store().funds[owner_slot], subsidy, _saturation_count), market_mutation_sink());
            population_store().epoch_income.write_scalar(owner_slot, saturating_add(
                population_store().epoch_income[owner_slot], subsidy,
                _saturation_count), market_mutation_sink());
            record_cohort_fiscal(owner_slot, transfer);
            trace_record_cashflow(
                cell, population_store().handle_for_slot(owner_slot),
                CASHFLOW_BUSINESS_SUBSIDY, subsidy, 0);
        }
    }
    // Tax positive net operating income only after inputs, actually paid wages,
    // and positive business tax are known. Tax/subsidy transfers themselves are
    // intentionally excluded from this base and losses never cross a cycle.
    if (income_tax_active) for (size_t owner_index = 0; owner_index < payroll_owners.size(); ++owner_index) {
        const int32_t owner_signature = payroll_owners[owner_index];
        const int32_t owner_slot = find_cohort_slot(cell, owner_signature);
        if (owner_slot < 0) continue;
        int64_t net_operating_income = 0;
        for (int32_t gi = owner_group_offsets[owner_index];
             gi < owner_group_offsets[owner_index + 1]; ++gi) {
            const int32_t g = owner_groups[static_cast<size_t>(gi)];
            const int64_t costs = saturating_add(
                saturating_add(saturating_add(buildings_store().last_input_cost[g],
                               buildings_store().last_wages_paid[g],
                               _saturation_count),
                    buildings_store().last_maintenance_cost[g], _saturation_count),
                business_tax_active
                    ? business_tax_by_group[g - begin] : 0,
                _saturation_count);
            net_operating_income = saturating_add(
                net_operating_income,
                saturating_sub(operation_receipts_by_group[g - begin], costs,
                               _saturation_count),
                _saturation_count);
        }
        net_operating_income = std::max<int64_t>(0, net_operating_income);
        const int32_t signature = static_cast<int32_t>(
            population_store().signature_id[owner_slot]);
        const int32_t profession = signature >= 0 &&
                signature < static_cast<int32_t>(_signatures.size())
            ? _signatures[signature].profession_id : -1;
        const int32_t income_rate = frozen_tax_rate(
            cell, CountryApi::TAX_INCOME, profession);
        const int32_t income_mode = frozen_tax_mode(
            cell, CountryApi::TAX_INCOME, profession);
        int64_t income_tax = 0;
        if (income_mode == CountryApi::TAX_MODE_ABSOLUTE) {
            // Settled in settle_absolute_daily_taxes_for_cell.
        } else if (income_rate < 0) {
            if (owner_slot < static_cast<int32_t>(
                    _income_taxable_base_by_slot.size())) {
                _income_taxable_base_by_slot[owner_slot] = saturating_add(
                    _income_taxable_base_by_slot[owner_slot],
                    net_operating_income, _saturation_count);
            }
        } else {
            income_tax = apply_fiscal_tax(
                cell, CountryApi::TAX_INCOME, net_operating_income,
                income_rate, income_mode, _saturation_count);
            record_cohort_fiscal(owner_slot, income_tax);
        }
        if (income_tax == 0) continue;
        touch_accounting_slot(owner_slot);
        population_store().funds.write_scalar(owner_slot, saturating_sub(
            population_store().funds[owner_slot], income_tax, _saturation_count), market_mutation_sink());
        if (income_tax > 0)
            trace_record_cashflow(cell, population_store().handle_for_slot(owner_slot),
                                  CASHFLOW_INCOME_TAX, 0, income_tax);
        else
            trace_record_cashflow(cell, population_store().handle_for_slot(owner_slot),
                                  CASHFLOW_INCOME_SUBSIDY, -income_tax, 0);
    }
    {
    // Prices are not written until the signal pass below.
    LivingCostMemoScope margin_memo(*this);
    for (int32_t g = begin; g < end; ++g) {
        const auto group = building_view(static_cast<size_t>(g));
        const int64_t owner_livelihood = saturating_mul(saturating_mul(
            living_cost_for_signature(cell, group.owner_signature_id, -1,
                                      _saturation_count),
            std::max<int64_t>(0, group.filled_owner), _saturation_count),
            std::max(1, _epoch_days.get()), _saturation_count);
        const int64_t realized_cost = saturating_add(saturating_add(
            saturating_add(group.last_input_cost, group.last_base_wages_due,
                _saturation_count),
            group.last_maintenance_cost, _saturation_count),
            owner_livelihood, _saturation_count);
        // last_revenue is the producer cash actually retained after positive
        // business tax withholding. Only a negative business transfer is paid
        // after production, so add that subsidy without double-charging tax.
        const int64_t after_business_revenue = business_tax_active
            ? saturating_sub(
                group.last_revenue,
                std::min<int64_t>(0, business_transfer_by_group[g - begin]),
                _saturation_count)
            : group.last_revenue;
        int64_t margin = realized_cost <= 0 ? 0 : mul_div_sat(
            saturating_sub(after_business_revenue, realized_cost,
                           _saturation_count),
            Q16_ONE, std::max<int64_t>(MONEY_SCALE, realized_cost), _saturation_count);
        buildings_store().realized_profit_margin_q16.write_scalar(g,
            static_cast<int32_t>(std::clamp<int64_t>(margin, -Q16_ONE, Q16_ONE)),
            market_mutation_sink());
    }
    }

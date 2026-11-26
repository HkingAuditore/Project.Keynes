        size_t offer_cursor = 0;
        for (int32_t good : touched_goods) {
            while (offer_cursor < offers.size() && offers[offer_cursor].good < good)
                ++offer_cursor;
            const size_t good_begin = offer_cursor;
            while (offer_cursor < offers.size() && offers[offer_cursor].good == good)
                ++offer_cursor;
            const size_t good_end = offer_cursor;
            const int64_t buy_price = std::max<int64_t>(1, mul_div_sat(
                market_store().price[market_store().index(market, good)],
                std::max<int32_t>(1, buy_factor_by_good[good]),
                Q16_ONE, _saturation_count));
            const int64_t merchant_total = std::min<int64_t>(quota_by_good[good],
                mul_div_sat(budget_by_good[good], GOODS_SCALE,
                    std::max<int64_t>(
                        1, procurement_outlay_price_by_good[good]),
                    _saturation_count));
            int64_t merchant_remaining = merchant_total;
            size_t merchant_i = good_begin;
            while (merchant_i < good_end && merchant_remaining > 0) {
                size_t tier_end = merchant_i + 1;
                while (tier_end < good_end &&
                       offers[tier_end].unit_cost ==
                           offers[merchant_i].unit_cost) {
                    ++tier_end;
                }
                int64_t tier_sellable = 0;
                for (size_t j = merchant_i; j < tier_end; ++j) {
                    tier_sellable = saturating_add(
                        tier_sellable, offers[j].sellable, _saturation_count);
                }
                if (tier_sellable <= merchant_remaining) {
                    for (size_t j = merchant_i; j < tier_end; ++j) {
                        offers[j].merchant_sold = std::max<int64_t>(
                            0, offers[j].sellable);
                        merchant_remaining = saturating_sub(
                            merchant_remaining, offers[j].merchant_sold,
                            _saturation_count);
                        if (offers[j].merchant_sold > 0)
                            accepted_anchor_sales.push_back(offers[j]);
                    }
                } else if (tier_sellable > 0) {
                    int64_t allocated = 0;
                    int64_t prefix = 0;
                    for (size_t j = merchant_i; j < tier_end; ++j) {
                        prefix = saturating_add(
                            prefix, offers[j].sellable, _saturation_count);
                        const int64_t next = mul_div_sat(
                            merchant_remaining, prefix, tier_sellable,
                            _saturation_count);
                        offers[j].merchant_sold = std::min<int64_t>(
                            offers[j].sellable,
                            std::max<int64_t>(0, next - allocated));
                        allocated = next;
                        if (offers[j].merchant_sold > 0)
                            accepted_anchor_sales.push_back(offers[j]);
                    }
                    merchant_remaining = 0;
                }
                merchant_i = tier_end;
            }
            // Inventory-target quotas gate normal merchant cash procurement
            // only. Producer support must buy every unit left unsold after
            // that pass (应收尽收): leftover sellable must not fall through to
            // discard while the cell still has support issuance budget.
            const int64_t remaining_sellable = std::max<int64_t>(
                0, sellable_by_good[good] - merchant_total);
            // Producer support is the final buyer in the local chain.  It
            // accepts every unit left after merchant procurement; cash is an
            // accounting settlement and must not turn a produced good into
            // an unowned remainder.
            const int64_t support_total = remaining_sellable;
            const int64_t monetary_issue_value = _good_monetary_issue_values[good];
            // Market prices are native currency-per-GOODS_SCALE units, not
            // Q16 values.  Producer support is one-fifth of that price;
            // applying Q16_ONE here would over-issue by 65536x.
            const int64_t support_unit_value = monetary_issue_value > 0
                ? monetary_issue_value
                : mul_div_sat(market_store().price[market_store().index(market, good)],
                    1, PRODUCER_SUPPORT_PRICE_DENOMINATOR,
                    _saturation_count);
            const int64_t total_support_paid = support_total > 0
                ? std::max<int64_t>(1, mul_div_sat(support_total,
                    support_unit_value, GOODS_SCALE, _saturation_count))
                : 0;
            int64_t support_remaining = support_total;
            int64_t support_cash_remaining = total_support_paid;
            size_t support_i = good_begin;
            while (support_i < good_end && support_remaining > 0) {
                size_t tier_end = support_i + 1;
                while (tier_end < good_end &&
                       offers[tier_end].unit_cost ==
                           offers[support_i].unit_cost) {
                    ++tier_end;
                }
                int64_t tier_unsold = 0;
                for (size_t j = support_i; j < tier_end; ++j) {
                    const int64_t unsold = std::max<int64_t>(
                        0, offers[j].sellable - offers[j].merchant_sold);
                    tier_unsold = saturating_add(
                        tier_unsold, unsold, _saturation_count);
                }
                if (tier_unsold <= support_remaining) {
                    for (size_t j = support_i; j < tier_end; ++j) {
                        offers[j].supported = std::max<int64_t>(
                            0, offers[j].sellable - offers[j].merchant_sold);
                        support_remaining = saturating_sub(
                            support_remaining, offers[j].supported,
                            _saturation_count);
                    }
                } else if (tier_unsold > 0) {
                    int64_t allocated = 0;
                    int64_t prefix = 0;
                    for (size_t j = support_i; j < tier_end; ++j) {
                        const int64_t unsold = std::max<int64_t>(
                            0, offers[j].sellable - offers[j].merchant_sold);
                        prefix = saturating_add(prefix, unsold, _saturation_count);
                        const int64_t next = mul_div_sat(
                            support_remaining, prefix, tier_unsold,
                            _saturation_count);
                        offers[j].supported = std::min<int64_t>(
                            unsold, std::max<int64_t>(0, next - allocated));
                        allocated = next;
                    }
                    support_remaining = 0;
                }
                support_i = tier_end;
            }
            for (size_t i = good_begin; i < good_end; ++i) {
                const int64_t cash_take = support_total > 0
                    ? mul_div_sat(total_support_paid, offers[i].supported,
                        support_total, _saturation_count)
                    : 0;
                offers[i].support_paid = std::min<int64_t>(
                    support_cash_remaining, std::max<int64_t>(0, cash_take));
                support_cash_remaining = std::max<int64_t>(
                    0, support_cash_remaining - offers[i].support_paid);
            }
            if (support_cash_remaining > 0) {
                for (size_t i = good_begin; i < good_end &&
                     support_cash_remaining > 0; ++i) {
                    if (offers[i].supported <= 0) continue;
                    offers[i].support_paid = saturating_add(
                        offers[i].support_paid, support_cash_remaining,
                        _saturation_count);
                    support_cash_remaining = 0;
                }
            }
        }
        // Monetary outputs share one cell-level issuance pool. Allocate the
        // pool by each offer's requested mint value, using a cumulative split
        // so gold and silver compete fairly and the last offer receives any
        // fixed-point remainder. The same physical output can never claim the
            // Monetary catalog goods do not bypass the local settlement chain.
        for (Offer &offer : offers) {
            if (offer.good < 0 || offer.good >= market_store().good_count.get()) continue;
            // Monetary catalog goods follow the same owner -> merchant ->
            // producer-support path as every other good.  They are physical
            // outputs here, not a separate minting sink.
            const int64_t issue_value = _good_monetary_issue_values[offer.good];
            if (issue_value <= 0 || offer.sellable <= 0) continue;
            offer.bullion_sold = offer.sellable;
        }
        GoodsBill procurement_bill;
        int32_t procurement_bill_good = -1;
        for (const Offer &offer : offers) {
            if (procurement_bill_good != offer.good) {
                procurement_bill = {};
                procurement_bill_good = offer.good;
            }
            auto group = building_at(static_cast<size_t>(offer.group));
            const int64_t issue_value = _good_monetary_issue_values[offer.good];
            const int64_t buy_price = std::max<int64_t>(1, mul_div_sat(
                market_store().price[market_store().index(market, offer.good)],
                std::max<int32_t>(1, buy_factor_by_good[offer.good]),
                Q16_ONE, _saturation_count));
            int64_t sold = offer.sellable;
            int64_t paid = 0;
            int64_t supported = offer.supported;
            int64_t support_paid = offer.support_paid;
            if (issue_value > 0) {
                // Bullion is never a merchant purchase.  Producer support
                // accepts the whole sellable batch and mints its face value.
                sold = 0;
                supported = offer.sellable;
                support_paid = mul_div_sat(supported, issue_value, GOODS_SCALE,
                    _saturation_count);
                paid = 0;
                _explicit_money_mint = saturating_add(
                    _explicit_money_mint, support_paid, _saturation_count);
                _bullion_money_issued = saturating_add(
                    _bullion_money_issued, support_paid, _saturation_count);
                if (_good_ids[offer.good] == "gold") {
                    _gold_accepted = saturating_add(_gold_accepted, supported, _saturation_count);
                    _gold_money_issued = saturating_add(
                        _gold_money_issued, support_paid, _saturation_count);
                } else {
                    _silver_accepted = saturating_add(_silver_accepted, supported, _saturation_count);
                    _silver_money_issued = saturating_add(
                        _silver_money_issued, support_paid, _saturation_count);
                }
            } else {
                sold = offer.merchant_sold;
                const int64_t base_payment = procurement_bill.add(sold, buy_price, _saturation_count);
                const TransactionQuote procurement_quote = quote_transaction(
                    cell, offer.good, base_payment, true, false,
                    _saturation_count, sold);
                const int64_t buyer_outlay = std::max<int64_t>(
                    0, procurement_quote.buyer_outlay);
                const int64_t merchant_paid = debit_local_merchants(
                    cell, buyer_outlay,
                                             CASHFLOW_MERCHANT_PROCUREMENT,
                                             &_saturation_count);
                if (merchant_paid != buyer_outlay) {
                    error = "merchant_purchase_payment_drift";
                    return false;
                }
                paid = base_payment;
                spent_by_good[offer.good] = saturating_add(
                    spent_by_good[offer.good], merchant_paid,
                    _saturation_count);
                merchant_procurement_remaining = std::max<int64_t>(
                    0, merchant_procurement_remaining - merchant_paid);
                _merchant_procurement_spent = saturating_add(
                    _merchant_procurement_spent, merchant_paid,
                    _saturation_count);
                const int64_t retail_value = mul_div_sat(
                    sold, market_store().price[market_store().index(market, offer.good)],
                    GOODS_SCALE, _saturation_count);
                _merchant_procurement_retail_value = saturating_add(
                    _merchant_procurement_retail_value, retail_value,
                    _saturation_count);
                _merchant_procurement_factor_weighted_cash_q16 =
                    saturating_add(
                        _merchant_procurement_factor_weighted_cash_q16,
                        saturating_mul(merchant_paid,
                            buy_factor_by_good[offer.good],
                            _saturation_count),
                        _saturation_count);
            }
            if (supported > 0) {
                if (issue_value <= 0)
                    _explicit_money_mint = saturating_add(
                        _explicit_money_mint, support_paid, _saturation_count);
                _producer_support_money_issued = saturating_add(
                    _producer_support_money_issued, support_paid,
                    _saturation_count);
                _production_output_supported = saturating_add(
                    _production_output_supported, supported,
                    _saturation_count);
            }
            int64_t business_tax = 0;
            const int64_t producer_receipt = saturating_add(
                paid, support_paid, _saturation_count);
            // Tax the same gross receipt shown by the building, including
            // producer support and bullion issuance. Negative business tax is
            // settled once against eligible costs after payroll and maintenance.
            if (business_tax_active) {
                const auto tax_group = building_view(static_cast<size_t>(offer.group));
                const int32_t business_rate = frozen_tax_rate(
                    cell, CountryApi::TAX_BUSINESS,
                    tax_group.type_id);
                const int32_t business_mode = frozen_tax_mode(
                    cell, CountryApi::TAX_BUSINESS,
                    tax_group.type_id);
                // Absolute business tax is a per-building daily levy settled in
                // settle_absolute_daily_taxes_for_cell, not per receipt.
                if (business_rate > 0 &&
                    business_mode != CountryApi::TAX_MODE_ABSOLUTE) {
                    business_tax = apply_fiscal_tax(
                        cell, CountryApi::TAX_BUSINESS,
                        producer_receipt,
                        business_rate, business_mode, _saturation_count);
                    record_cohort_fiscal(offer.owner_slot, business_tax);
                }
            }
            const int64_t producer_after_business_tax = saturating_sub(
                producer_receipt, business_tax, _saturation_count);
            const int64_t total_paid = producer_after_business_tax;
            if (issue_value > 0)
                group.last_bullion_mint_receipt = saturating_add(
                    group.last_bullion_mint_receipt, support_paid, _saturation_count);
            else
                group.last_market_receipt = saturating_add(
                    group.last_market_receipt, paid, _saturation_count);
            group.last_producer_support_receipt = saturating_add(
                group.last_producer_support_receipt, support_paid,
                _saturation_count);
            if (business_tax > 0)
                group.last_business_tax_paid = saturating_add(
                    group.last_business_tax_paid, business_tax,
                    _saturation_count);
            else if (business_tax < 0)
                group.last_business_subsidy_received = saturating_add(
                    group.last_business_subsidy_received, -business_tax,
                    _saturation_count);
            if (owner_operation_tax_active)
                operation_receipts_by_group[offer.group - begin] =
                    saturating_add(
                        operation_receipts_by_group[offer.group - begin],
                        paid, _saturation_count);
            if (business_tax_active)
                business_transfer_by_group[offer.group - begin] =
                    saturating_add(
                        business_transfer_by_group[offer.group - begin],
                        business_tax, _saturation_count);
            if (business_tax > 0)
                business_tax_by_group[offer.group - begin] = saturating_add(
                    business_tax_by_group[offer.group - begin], business_tax,
                    _saturation_count);
            const int64_t accepted = saturating_add(
                sold, supported, _saturation_count);
            touch_accounting_slot(offer.owner_slot);
            population_store().funds.write_scalar(offer.owner_slot, saturating_add(
                population_store().funds[offer.owner_slot], total_paid, _saturation_count), market_mutation_sink());
            population_store().epoch_income.write_scalar(offer.owner_slot, saturating_add(
                population_store().epoch_income[offer.owner_slot], total_paid,
                _saturation_count), market_mutation_sink());
            trace_record_cashflow(cell, population_store().handle_for_slot(offer.owner_slot),
                                  CASHFLOW_OWNER_OPERATIONS, paid, 0);
            trace_record_cashflow(cell, population_store().handle_for_slot(offer.owner_slot),
                                  CASHFLOW_PRODUCER_SUPPORT, support_paid, 0);
            if (business_tax > 0)
                trace_record_cashflow(cell,
                    population_store().handle_for_slot(offer.owner_slot),
                    CASHFLOW_BUSINESS_TAX, 0, business_tax);
            else if (business_tax < 0)
                trace_record_cashflow(cell,
                    population_store().handle_for_slot(offer.owner_slot),
                    CASHFLOW_BUSINESS_SUBSIDY, -business_tax, 0);
            const int64_t offer_stock_index =
                market_store().index(market, offer.good);
            audit_touch_market_lane(
                static_cast<size_t>(offer_stock_index));
            market_store().stock.write_scalar(offer_stock_index, saturating_add(
                market_store().stock[offer_stock_index], accepted,
                _saturation_count), market_mutation_sink());
            if (issue_value > 0) {
                // Coined bullion is consumed by the money system: the sold batch
                // was minted into currency (see the issue_value branch above), so
                // it must not linger as market stock. Net stock change for these
                // goods is zero (+accepted then -sold, and supported==0 here).
                // Record the removal as an explicit goods-conservation sink so the
                // closing-stock check stays balanced. Without this, gold/silver
                // stock accrues as ghost inventory, the utilization planner reads
                // it as unsellable surplus, and throttles production to the probe
                // floor -> owner/employee targets collapse -> mines shed workers.
                market_store().stock.write_scalar(offer_stock_index, saturating_sub(
                    market_store().stock[offer_stock_index], supported,
                    _saturation_count), market_mutation_sink());
                _bullion_stock_consumed = saturating_add(
                    _bullion_stock_consumed, supported, _saturation_count);
            }
            group.last_sold = saturating_add(
                group.last_sold, accepted, _saturation_count);
            const int64_t unsold = offer.sellable - accepted;
            const int32_t producer_signal = market_signal_index(cell, offer.good);
            if (producer_signal >= 0 && producer_signal < static_cast<int32_t>(
                    _epoch_producer_merchant_sold_current.size())) {
                // Bullion issuance and producer support are non-market sinks.
                // Only purchases debited from merchant cash count as sell-through.
                const int64_t merchant_sold = issue_value > 0 ? 0 : sold;
                _epoch_producer_merchant_sold_current[producer_signal] =
                    saturating_add(
                        _epoch_producer_merchant_sold_current[producer_signal],
                        merchant_sold, _saturation_count);
                // Unsold sellable output is not destroyed.  It remains local
                // inventory and can be purchased or producer-supported by the
                // next settlement pass.
            }
            if (unsold > 0)
                market_store().stock.write_scalar(offer_stock_index, saturating_add(
                    market_store().stock[offer_stock_index], unsold,
                    _saturation_count), market_mutation_sink());
            group.last_revenue = saturating_add(
                group.last_revenue, total_paid, _saturation_count);
            _production_output_stock = saturating_add(
                _production_output_stock, offer.sellable, _saturation_count);
            _producer_revenue = saturating_add(
                _producer_revenue, total_paid, _saturation_count);
            if (_good_storage_modes[offer.good] == 1) {
                _cycle_flow_produced = saturating_add(
                    _cycle_flow_produced, accepted, _saturation_count);
            }
        }

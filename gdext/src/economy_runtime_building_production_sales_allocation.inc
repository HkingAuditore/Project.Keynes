        for (Offer &offer : offers) {
            if (offer.group < 0 ||
                offer.group >= static_cast<int32_t>(building_count()) ||
                offer.qty <= 0 || offer.output_index < 0) continue;
            const auto group = building_view(static_cast<size_t>(offer.group));
            if (offer.type_id < 0 ||
                offer.type_id >= static_cast<int32_t>(_building_types.size()))
                continue;
            const BuildingType &type = _building_types[offer.type_id];
            const int64_t allocated = allocated_output_operating_cost(
                type, offer.output_index,
                std::max<int64_t>(0, group.last_operating_cost),
                _saturation_count);
            offer.unit_cost = mul_div_sat(
                allocated, GOODS_SCALE, offer.qty, _saturation_count);
        }
        std::stable_sort(offers.begin(), offers.end(), [](const Offer &a, const Offer &b) {
            if (a.good != b.good) return a.good < b.good;
            if (a.unit_cost != b.unit_cost) return a.unit_cost < b.unit_cost;
            return a.group < b.group;
        });
        thread_local std::vector<int64_t> sellable_by_good;
        thread_local std::vector<int64_t> quota_by_good;
        thread_local std::vector<int64_t> purchase_value_by_good;
        thread_local std::vector<int64_t> budget_by_good;
        thread_local std::vector<int64_t> spent_by_good;
        thread_local std::vector<int64_t> weight_by_good;
        thread_local std::vector<int64_t> procurement_outlay_price_by_good;
        thread_local std::vector<int32_t> buy_factor_by_good;
        thread_local std::vector<int32_t> touched_goods;
        const size_t good_count = static_cast<size_t>(market_store().good_count.get());
        sellable_by_good.resize(good_count);
        quota_by_good.resize(good_count);
        purchase_value_by_good.resize(good_count);
        budget_by_good.resize(good_count);
        spent_by_good.resize(good_count);
        weight_by_good.resize(good_count);
        procurement_outlay_price_by_good.resize(good_count);
        buy_factor_by_good.resize(good_count);
        touched_goods.clear();
        int32_t last_touched = -1;
        for (Offer &offer : offers) {
            if (offer.owner_slot >= 0 &&
                offer.owner_slot < static_cast<int32_t>(retention_slot_stamp.size()) &&
                retention_slot_stamp[offer.owner_slot] == retention_generation) {
                const size_t owner = static_cast<size_t>(
                    retention_owner_by_slot[offer.owner_slot]);
            if (_survival_food_good_mask[offer.good] != 0) {
                    // All survival-food outputs feed the same aggregate calorie
                    // pool. A staple output must not suppress retention of fish,
                    // game, protein, or produce from the same owner.
                    offer.retained = std::min<int64_t>(offer.qty, std::max<int64_t>(
                        0, retention_food_targets[owner] - retention_food_used[owner]));
                    retention_food_used[owner] = saturating_add(
                        retention_food_used[owner], offer.retained, _saturation_count);
                } else if (_survival_clothing_good_mask[offer.good] != 0) {
                    offer.retained = std::min<int64_t>(offer.qty, std::max<int64_t>(
                        0, retention_clothing_targets[owner] -
                            retention_clothing_used[owner]));
                    retention_clothing_used[owner] = saturating_add(
                        retention_clothing_used[owner], offer.retained,
                        _saturation_count);
            } else {
                // All other goods use the same owner consumption plan that
                // was compiled above.  Do not silently bypass it merely
                // because the output is not classified as food or clothing.
                const int32_t lane = retention_lane(owner, offer.good);
                if (lane >= 0) {
                    offer.retained = std::min<int64_t>(offer.qty, std::max<int64_t>(
                        0, retention_targets[lane] - retention_used[lane]));
                    retention_used[lane] = saturating_add(
                        retention_used[lane], offer.retained, _saturation_count);
                }
                }
            }
            offer.sellable = offer.qty - offer.retained;
            const int32_t producer_signal = market_signal_index(cell, offer.good);
            if (producer_signal >= 0 && producer_signal < static_cast<int32_t>(
                    _epoch_producer_sellable_current.size())) {
                _epoch_producer_sellable_current[producer_signal] = saturating_add(
                    _epoch_producer_sellable_current[producer_signal],
                    offer.sellable, _saturation_count);
            }
            if (offer.retained > 0) {
                _owner_retained_outputs.push_back(
                    {offer.owner_slot, offer.good, offer.group, offer.retained});
            }
            if (offer.sellable > 0) {
                sellable_by_good[offer.good] = saturating_add(
                    sellable_by_good[offer.good], offer.sellable, _saturation_count);
                if (offer.good != last_touched) {
                    // Offers are sorted by good. Reset only the sparse goods
                    // touched by this cell instead of clearing every catalog good.
                    sellable_by_good[offer.good] = offer.sellable;
                    quota_by_good[offer.good] = 0;
                    purchase_value_by_good[offer.good] = 0;
                    budget_by_good[offer.good] = 0;
                    spent_by_good[offer.good] = 0;
                    weight_by_good[offer.good] = 0;
                    procurement_outlay_price_by_good[offer.good] = 0;
                    buy_factor_by_good[offer.good] = 0;
                    touched_goods.push_back(offer.good);
                    last_touched = offer.good;
                }
            }
        }
        int64_t total_purchase_value = 0;
        for (int32_t good : touched_goods) {
            const int64_t monetary_issue_value = _good_monetary_issue_values[good];
            if (monetary_issue_value > 0) {
                // Bullion never competes for merchant inventory cash.  Its
                // entire sellable remainder is settled by producer support,
                // which mints the catalogued face value below.
                quota_by_good[good] = 0;
                purchase_value_by_good[good] = 0;
                budget_by_good[good] = 0;
                weight_by_good[good] = 0;
                procurement_outlay_price_by_good[good] = 1;
                buy_factor_by_good[good] = 0;
                continue;
            }
            const int32_t signal = market_signal_index(cell, good);
            const int64_t realized = signal >= 0
                ? _market_signals.realized_withdrawal_ema[signal] : 0;
            const int32_t flow = trade_flow_index(cell, good, false);
            const int64_t exports = flow >= 0 ? _trade_flows.export_ema[flow] : 0;
            const int64_t cold_start_supply = sellable_by_good[good] /
                std::max(1, _epoch_days.get());
            const int64_t target = merchant_inventory_target(
                market, good, signal, realized, exports, cold_start_supply,
                _saturation_count);
            if (_good_storage_modes[good] == 1) {
                // Cycle-flow goods cannot persist as inventory. Let the producer
                // attempt a low-price same-cycle clearing/support pass before the
                // remaining transient stock is discarded at the cell boundary.
                quota_by_good[good] = std::max<int64_t>(0, sellable_by_good[good]);
            } else {
                quota_by_good[good] = merchant_procurement_quota(
                    market, good, signal, sellable_by_good[good], target,
                    market_store().stock[market_store().index(market, good)], realized,
                    exports, _saturation_count);
            }
            buy_factor_by_good[good] = effective_merchant_buy_factor_q16(
                market, good, target,
                market_store().stock[market_store().index(market, good)], _saturation_count);
            const int64_t buy_price = std::max<int64_t>(1, mul_div_sat(
                market_store().price[market_store().index(market, good)],
                buy_factor_by_good[good], Q16_ONE, _saturation_count));
            const TransactionQuote procurement_quote = quote_transaction(
                cell, good, buy_price, false, false, _saturation_count, -1);
            const int64_t outlay_price = std::max<int64_t>(
                1, procurement_quote.buyer_outlay);
            procurement_outlay_price_by_good[good] = outlay_price;
            const int64_t base_weight = goods_cost(quota_by_good[good], outlay_price, _saturation_count);
            purchase_value_by_good[good] = base_weight;
            total_purchase_value = saturating_add(
                total_purchase_value, base_weight, _saturation_count);
            const bool survival_good = _survival_food_good_mask[good] != 0 ||
                _survival_clothing_good_mask[good] != 0;
            const int64_t protected_reserve = merchant_protected_reserve(signal);
            const bool input_gap = signal >= 0 &&
                protected_reserve >
                    market_store().stock[market_store().index(market, good)];
            if (survival_good) {
                _merchant_survival_procurement_required = saturating_add(
                    _merchant_survival_procurement_required, base_weight,
                    _saturation_count);
            } else if (input_gap) {
                _merchant_input_procurement_required = saturating_add(
                    _merchant_input_procurement_required, base_weight,
                    _saturation_count);
            }
            int64_t priority_q16 = Q16_ONE;
            if (_survival_food_good_mask[good] != 0 ||
                _survival_clothing_good_mask[good] != 0) {
                priority_q16 = saturating_add(
                    priority_q16, 2 * Q16_ONE, _saturation_count);
            }
            const int64_t market_index = market_store().index(market, good);
            priority_q16 = saturating_add(priority_q16, mul_div_sat(
                std::clamp<int64_t>(market_store().last_shortage_q16[market_index],
                                    0, Q16_ONE),
                2 * Q16_ONE, Q16_ONE, _saturation_count),
                _saturation_count);
            if (signal >= 0) {
                const int64_t reserve = merchant_protected_reserve(signal);
                const int64_t stock = std::max<int64_t>(
                    0, market_store().stock[market_index]);
                if (reserve > stock) {
                    priority_q16 = saturating_add(priority_q16, mul_div_sat(
                        reserve - stock, 2 * Q16_ONE,
                        std::max<int64_t>(1, reserve), _saturation_count),
                        _saturation_count);
                }
            }
            weight_by_good[good] = mul_div_sat(
                base_weight, priority_q16, Q16_ONE, _saturation_count);
        }
        const int64_t allocated_budget = std::min(
            merchant_procurement_remaining, total_purchase_value);
        _merchant_procurement_opportunity = saturating_add(
            _merchant_procurement_opportunity, total_purchase_value, _saturation_count);
        _merchant_procurement_allocated = saturating_add(
            _merchant_procurement_allocated, allocated_budget, _saturation_count);
        int64_t remaining_budget = allocated_budget;
        auto procurement_tier = [&](int32_t good) {
            if (_survival_food_good_mask[good] != 0 ||
                _survival_clothing_good_mask[good] != 0) return 0;
            const int32_t signal = market_signal_index(cell, good);
            if (signal >= 0 &&
                merchant_protected_reserve(signal) >
                    market_store().stock[market_store().index(market, good)]) return 1;
            return 2;
        };
        auto allocate_tier = [&](int tier) {
            if (remaining_budget <= 0) return;
            int64_t tier_cap = 0;
            int64_t tier_weight = 0;
            for (int32_t good : touched_goods) {
                if (procurement_tier(good) != tier) continue;
                tier_cap = saturating_add(
                    tier_cap, purchase_value_by_good[good], _saturation_count);
                tier_weight = saturating_add(
                    tier_weight, weight_by_good[good], _saturation_count);
            }
            int64_t tier_budget = std::min(remaining_budget, tier_cap);
            const int64_t committed = tier_budget;
            while (tier_budget > 0 && tier_weight > 0) {
                bool capped_any = false;
                for (int32_t good : touched_goods) {
                    if (procurement_tier(good) != tier) continue;
                    const int64_t weight = weight_by_good[good];
                    const int64_t cap = purchase_value_by_good[good];
                    if (weight <= 0 || cap <= 0) continue;
                    const int64_t share = mul_div_sat(
                        tier_budget, weight, tier_weight, _saturation_count);
                    if (share < cap) continue;
                    budget_by_good[good] = cap;
                    tier_budget = std::max<int64_t>(0, tier_budget - cap);
                    tier_weight = std::max<int64_t>(0, tier_weight - weight);
                    weight_by_good[good] = 0;
                    capped_any = true;
                }
                if (!capped_any) break;
            }
            int64_t weight_prefix = 0;
            int64_t distributed = 0;
            for (int32_t good : touched_goods) {
                if (procurement_tier(good) != tier) continue;
                const int64_t weight = weight_by_good[good];
                if (weight <= 0 || tier_weight <= 0) continue;
                weight_prefix = saturating_add(
                    weight_prefix, weight, _saturation_count);
                const int64_t next = mul_div_sat(
                    tier_budget, weight_prefix, tier_weight, _saturation_count);
                budget_by_good[good] = std::min<int64_t>(
                    purchase_value_by_good[good], std::max<int64_t>(
                        0, next - distributed));
                distributed = next;
            }
            int64_t assigned = 0;
            for (int32_t good : touched_goods) {
                if (procurement_tier(good) == tier) assigned = saturating_add(
                    assigned, budget_by_good[good], _saturation_count);
            }
            int64_t rounding = std::max<int64_t>(0, committed - assigned);
            for (int32_t good : touched_goods) {
                if (rounding <= 0) break;
                if (procurement_tier(good) != tier) continue;
                const int64_t headroom = std::max<int64_t>(
                    0, purchase_value_by_good[good] - budget_by_good[good]);
                const int64_t extra = std::min(headroom, rounding);
                budget_by_good[good] += extra;
                rounding -= extra;
            }
            remaining_budget = std::max<int64_t>(
                0, remaining_budget - committed);
            if (tier == 0) {
                _merchant_survival_procurement_allocated = saturating_add(
                    _merchant_survival_procurement_allocated, committed,
                    _saturation_count);
            } else if (tier == 1) {
                _merchant_input_procurement_allocated = saturating_add(
                    _merchant_input_procurement_allocated, committed,
                    _saturation_count);
            }
        };
        allocate_tier(0);
        allocate_tier(1);
        allocate_tier(2);

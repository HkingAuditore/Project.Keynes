    if (view == "goods") {
        const size_t goods = static_cast<size_t>(std::max(0, good_count));
        std::vector<int64_t> stock(goods, 0), demand(goods, 0), business(goods, 0),
            supply(goods, 0), withdrawal(goods, 0), imports(goods, 0),
            exports(goods, 0), value(goods, 0), price_weighted(goods, 0),
            price_weight(goods, 0), anchor_weighted(goods, 0), anchor_weight(goods, 0),
            shortage_weighted(goods, 0), shortage_weight(goods, 0),
            shortage_cells(goods, 0), market_cells(goods, 0);
        std::vector<int32_t> price_min(goods, std::numeric_limits<int32_t>::max()),
            price_max(goods, 0);
        NativeEconomyRuntime *self = const_cast<NativeEconomyRuntime *>(this);
        for (const int32_t cell : cells) {
            if (cell_population(cell) <= 0) continue;
            ++populated_cells;
            note_state_day(cell);
            const int32_t market = market_store().cell_to_market[cell];
            if (market < 0) continue;
            for (int32_t good = 0; good < good_count; ++good) {
                const size_t g = static_cast<size_t>(good);
                const int64_t index = market_store().index(market, good);
                const int64_t cell_stock = std::max<int64_t>(0, market_store().stock[index]);
                const int64_t cell_demand = std::max<int64_t>(0, market_store().demand_ema[index]);
                const int32_t signal = market_signal_index(cell, good);
                const int64_t cell_business = signal >= 0
                    ? std::max<int64_t>(0, _market_signals.business_demand_ema[signal]) : 0;
                const int64_t cell_supply = signal >= 0
                    ? std::max<int64_t>(0, _market_signals.offered_supply_ema[signal]) : 0;
                const int32_t flow = self->trade_flow_index(cell, good, false);
                const int64_t cell_import = flow >= 0 ? _trade_flows.import_ema[flow] : 0;
                const int64_t cell_export = flow >= 0 ? _trade_flows.export_ema[flow] : 0;
                if (cell_stock <= 0 && cell_demand <= 0 && cell_business <= 0 &&
                    cell_supply <= 0 && cell_import <= 0 && cell_export <= 0)
                    continue;
                ++market_cells[g];
                const int32_t price = std::max<int32_t>(0, market_store().price[index]);
                add(stock[g], cell_stock);
                add(demand[g], cell_demand);
                add(business[g], cell_business);
                add(supply[g], cell_supply);
                if (signal >= 0)
                    add(withdrawal[g], std::max<int64_t>(
                        0, _market_signals.realized_withdrawal_ema[signal]));
                add(imports[g], std::max<int64_t>(0, cell_import));
                add(exports[g], std::max<int64_t>(0, cell_export));
                add(value[g], mul_div_sat(cell_stock, price, GOODS_SCALE, sat));
                const int64_t weight = std::max<int64_t>(1, saturating_add(
                    cell_demand, cell_business, sat));
                weigh(price_weighted[g], price, weight);
                add(price_weight[g], weight);
                if (signal >= 0 && _market_signals.cost_anchor_price[signal] > 0) {
                    weigh(anchor_weighted[g], _market_signals.cost_anchor_price[signal], weight);
                    add(anchor_weight[g], weight);
                }
                const int64_t shortage = std::clamp<int64_t>(
                    market_store().last_shortage_q16[index], 0, Q16_ONE);
                weigh(shortage_weighted[g], shortage, weight);
                add(shortage_weight[g], weight);
                if (shortage >= Q16_ONE / 4) ++shortage_cells[g];
                price_min[g] = std::min(price_min[g], price);
                price_max[g] = std::max(price_max[g], price);
            }
        }
        PackedInt32Array good_indices, prices, mins, maxes, anchors, shortages;
        PackedStringArray stable_ids, categories;
        PackedInt64Array stock_out, demand_out, business_out, supply_out, withdrawal_out,
            import_out, export_out, value_out, shortage_cells_out, market_cells_out;
        for (int32_t good = 0; good < good_count; ++good) {
            const size_t g = static_cast<size_t>(good);
            if (market_cells[g] <= 0) continue;
            good_indices.push_back(good);
            stable_ids.push_back(from_utf8(_good_ids[good]));
            categories.push_back(g < _good_category_ids.size()
                ? from_utf8(_good_category_ids[g]) : String());
            stock_out.push_back(stock[g]);
            demand_out.push_back(demand[g]);
            business_out.push_back(business[g]);
            supply_out.push_back(supply[g]);
            withdrawal_out.push_back(withdrawal[g]);
            import_out.push_back(imports[g]);
            export_out.push_back(exports[g]);
            value_out.push_back(value[g]);
            prices.push_back(clamp_q16(price_weighted[g], price_weight[g]));
            anchors.push_back(clamp_q16(anchor_weighted[g], anchor_weight[g]));
            mins.push_back(price_min[g] == std::numeric_limits<int32_t>::max()
                ? 0 : price_min[g]);
            maxes.push_back(price_max[g]);
            shortages.push_back(clamp_q16(shortage_weighted[g], shortage_weight[g]));
            shortage_cells_out.push_back(shortage_cells[g]);
            market_cells_out.push_back(market_cells[g]);
        }
        out["goods_scale"] = GOODS_SCALE;
        out["good_indices"] = good_indices;
        out["good_stable_ids"] = stable_ids;
        out["category_ids"] = categories;
        out["stock"] = stock_out;
        out["demand_ema"] = demand_out;
        out["business_demand_ema"] = business_out;
        out["offered_supply_ema"] = supply_out;
        out["realized_withdrawal_ema"] = withdrawal_out;
        out["trade_import_ema"] = import_out;
        out["trade_export_ema"] = export_out;
        out["inventory_value"] = value_out;
        out["price"] = prices;
        out["cost_anchor_price"] = anchors;
        out["price_min"] = mins;
        out["price_max"] = maxes;
        out["shortage_q16"] = shortages;
        out["shortage_cell_count"] = shortage_cells_out;
        out["market_cell_count"] = market_cells_out;
        finish(out);
        return out;
    }

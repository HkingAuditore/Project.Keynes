    if (view == "settlements") {
        struct SettlementRow {
            int32_t cell = -1;
            PopulationBucket population;
            BuildingBucket buildings;
            int32_t worst_good = -1;
            int32_t worst_shortage = 0;
        };
        std::vector<SettlementRow> rows;
        std::vector<int32_t> profession_offsets{0};
        std::vector<int32_t> profession_ids;
        std::vector<int64_t> profession_population;
        std::vector<int32_t> profession_satisfaction;
        std::vector<PopulationBucket> scratch(static_cast<size_t>(std::max(0, profession_count)));
        std::vector<int32_t> touched;
        for (const int32_t cell : cells) {
            if (cell_population(cell) <= 0) continue;
            ++populated_cells;
            note_state_day(cell);
            const int64_t days = cell_elapsed_days(cell);
            SettlementRow row;
            row.cell = cell;
            touched.clear();
            population_store().for_each_in_cell(cell, [&](int32_t slot) {
                accumulate_cohort(row.population, slot, days);
                const uint32_t signature = population_store().signature_id[
                    static_cast<size_t>(slot)];
                if (signature >= _signatures.size()) return;
                const int32_t profession = _signatures[signature].profession_id;
                if (profession < 0 || profession >= profession_count) return;
                PopulationBucket &bucket = scratch[static_cast<size_t>(profession)];
                if (bucket.cohorts == 0) touched.push_back(profession);
                accumulate_cohort(bucket, slot, days);
            });
            std::sort(touched.begin(), touched.end());
            for (const int32_t profession : touched) {
                PopulationBucket &bucket = scratch[static_cast<size_t>(profession)];
                profession_ids.push_back(profession);
                profession_population.push_back(bucket.population);
                profession_satisfaction.push_back(
                    clamp_q16(bucket.composite_weighted, bucket.population));
                bucket = PopulationBucket{};
            }
            for (int32_t g = group_begin(cell); g < group_end(cell); ++g) {
                const auto group = building_view(static_cast<size_t>(g));
                if (group.cell != cell) continue;
                accumulate_group(row.buildings, group, days);
            }
            const int32_t market = market_store().cell_to_market[cell];
            if (market >= 0) {
                int64_t worst_score = 0;
                for (int32_t good = 0; good < good_count; ++good) {
                    const int64_t index = market_store().index(market, good);
                    const int64_t shortage = std::clamp<int64_t>(
                        market_store().last_shortage_q16[index], 0, Q16_ONE);
                    const int64_t demand = std::max<int64_t>(0, market_store().demand_ema[index]);
                    if (shortage <= 0 || demand <= 0) continue;
                    const int64_t score = saturating_mul(shortage, demand, sat);
                    if (score > worst_score) {
                        worst_score = score;
                        row.worst_good = good;
                        row.worst_shortage = static_cast<int32_t>(shortage);
                    }
                }
            }
            profession_offsets.push_back(static_cast<int32_t>(profession_ids.size()));
            rows.push_back(std::move(row));
        }
        std::vector<int32_t> order(rows.size());
        std::iota(order.begin(), order.end(), 0);
        std::sort(order.begin(), order.end(), [&](int32_t a, int32_t b) {
            const int64_t pa = rows[static_cast<size_t>(a)].population.population;
            const int64_t pb = rows[static_cast<size_t>(b)].population.population;
            if (pa != pb) return pa > pb;
            return rows[static_cast<size_t>(a)].cell < rows[static_cast<size_t>(b)].cell;
        });
        const int32_t total = static_cast<int32_t>(order.size());
        const int32_t page_limit = limit <= 0 ? OVERVIEW_MAX_ROWS
                                              : std::clamp(limit, 1, OVERVIEW_MAX_ROWS);
        const int32_t begin = std::clamp(offset, 0, total);
        const int32_t end = std::min(total, begin + page_limit);
        PackedInt32Array cell_indices, tiers, satisfaction, survival, worst_goods,
            worst_shortages, out_offsets, out_professions, out_profession_satisfaction;
        PackedStringArray names, prosperity_names;
        PackedByteArray named;
        PackedInt64Array population, funds, income, expense, tax, unemployed,
            jobs_required, jobs_filled, units, suspended, revenue, profit, wages_due,
            wages_paid, state_days, out_profession_population;
        out_offsets.push_back(0);
        for (int32_t p = begin; p < end; ++p) {
            const int32_t index = order[static_cast<size_t>(p)];
            const SettlementRow &row = rows[static_cast<size_t>(index)];
            const int32_t cell = row.cell;
            cell_indices.push_back(cell);
            const int32_t tier = cell < static_cast<int32_t>(_settlements.tier.size())
                ? _settlements.tier[cell] : 0;
            tiers.push_back(tier);
            named.push_back(cell < static_cast<int32_t>(_settlements.name_active.size()) &&
                _settlements.name_active[cell] != 0 ? 1 : 0);
            names.push_back(from_utf8(settlement_name_for_cell(cell)));
            prosperity_names.push_back(tier >= 0 &&
                tier < static_cast<int32_t>(_prosperity_names.size())
                ? from_utf8(_prosperity_names[static_cast<size_t>(tier)]) : String());
            population.push_back(row.population.population);
            funds.push_back(row.population.funds);
            income.push_back(row.population.income_day);
            expense.push_back(row.population.expense_day);
            tax.push_back(row.population.tax_day);
            unemployed.push_back(row.population.unemployed);
            satisfaction.push_back(clamp_q16(row.population.composite_weighted,
                                             row.population.population));
            survival.push_back(clamp_q16(row.population.survival_weighted,
                                         row.population.population));
            jobs_required.push_back(row.buildings.jobs_required);
            jobs_filled.push_back(row.buildings.jobs_filled);
            units.push_back(row.buildings.units);
            suspended.push_back(row.buildings.suspended_units);
            revenue.push_back(row.buildings.revenue_day);
            int64_t cell_profit = row.buildings.revenue_day;
            cell_profit = saturating_add(cell_profit, -row.buildings.input_cost_day, sat);
            cell_profit = saturating_add(cell_profit, -row.buildings.wages_paid_day, sat);
            cell_profit = saturating_add(cell_profit, -row.buildings.maintenance_day, sat);
            profit.push_back(cell_profit);
            wages_due.push_back(row.buildings.wages_due_day);
            wages_paid.push_back(row.buildings.wages_paid_day);
            worst_goods.push_back(row.worst_good);
            worst_shortages.push_back(row.worst_shortage);
            state_days.push_back(cell < static_cast<int32_t>(_cell_last_settlement_day.size())
                ? _cell_last_settlement_day[cell] : int64_t{-1});
            for (int32_t k = profession_offsets[static_cast<size_t>(index)];
                 k < profession_offsets[static_cast<size_t>(index) + 1U]; ++k) {
                out_professions.push_back(profession_ids[static_cast<size_t>(k)]);
                out_profession_population.push_back(
                    profession_population[static_cast<size_t>(k)]);
                out_profession_satisfaction.push_back(
                    profession_satisfaction[static_cast<size_t>(k)]);
            }
            out_offsets.push_back(out_professions.size());
        }
        PackedStringArray good_ids;
        for (int32_t good = 0; good < good_count; ++good)
            good_ids.push_back(from_utf8(_good_ids[good]));
        out["total"] = total;
        out["offset"] = begin;
        out["limit"] = page_limit;
        out["has_more"] = end < total;
        out["cell_indices"] = cell_indices;
        out["settlement_names"] = names;
        out["name_active"] = named;
        out["prosperity_tiers"] = tiers;
        out["prosperity_names"] = prosperity_names;
        out["population"] = population;
        out["funds"] = funds;
        out["income_per_day"] = income;
        out["expense_per_day"] = expense;
        out["tax_per_day"] = tax;
        out["unemployed"] = unemployed;
        out["satisfaction_q16"] = satisfaction;
        out["survival_satisfaction_q16"] = survival;
        out["jobs_required"] = jobs_required;
        out["jobs_filled"] = jobs_filled;
        out["building_units"] = units;
        out["building_suspended_units"] = suspended;
        out["revenue_per_day"] = revenue;
        out["profit_per_day"] = profit;
        out["wages_due_per_day"] = wages_due;
        out["wages_paid_per_day"] = wages_paid;
        out["worst_shortage_good"] = worst_goods;
        out["worst_shortage_q16"] = worst_shortages;
        out["state_day"] = state_days;
        out["profession_offsets"] = out_offsets;
        out["profession_indices"] = out_professions;
        out["profession_population"] = out_profession_population;
        out["profession_satisfaction_q16"] = out_profession_satisfaction;
        out["good_ids"] = good_ids;
        finish(out);
        return out;
    }

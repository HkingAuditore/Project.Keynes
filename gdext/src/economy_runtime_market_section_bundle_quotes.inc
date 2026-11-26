    const auto cohort_cell = [&](int32_t slot) {
        const int32_t page = slot / COHORT_PAGE_SIZE;
        return page >= 0 && page < static_cast<int32_t>(population_store().page_cell.size())
            ? population_store().page_cell[page] : -1;
    };
    const auto component_quantity = [&](int32_t slot,
            const NeedComponent &component) {
        return effective_household_good_quantity(
            cohort_cell(slot), component.good_id, component.qty_per_need, sat);
    };
    const bool consumption_tax_active =
        (_epoch_active_tax_mask & static_cast<uint8_t>(
            1U << CountryApi::TAX_CONSUMPTION)) != 0;
    bool family_purchase_discount_active = false;
    for (int32_t local = 0; local < cohort_count; ++local) {
        if (family_purchase_pay_factor_q16(slots[local]) < Q16_ONE) {
            family_purchase_discount_active = true;
            break;
        }
    }
    const bool subsidy_settlement =
        consumption_tax_active || family_purchase_discount_active;
    const bool income_tax_active =
        (_epoch_active_tax_mask & static_cast<uint8_t>(
            1U << CountryApi::TAX_INCOME)) != 0;
    const auto household_quote = [&](int32_t slot, int32_t variant_id,
                                     int64_t base_price) {
        if (!consumption_tax_active) return base_price;
        int64_t quoted = base_price;
        const int32_t cell = cohort_cell(slot);
        const VariantChoice &variant = _variants[variant_id];
        for (int32_t c = 0; c < variant.component_count; ++c) {
            const NeedComponent &component =
                _components[variant.component_begin + c];
            const int32_t rate = frozen_tax_rate(
                cell, CountryApi::TAX_CONSUMPTION,
                component.good_id);
            if (rate <= 0) continue;
            const int64_t component_value = goods_cost(
                component_quantity(slot, component),
                market_store().price[market_store().index(market, component.good_id)], sat);
            int64_t tax_quote = mul_div_sat(component_value, rate, 10000, sat);
            if (((component_value % 10000) * (rate % 10000)) % 10000 != 0)
                tax_quote = saturating_add(tax_quote, 1, sat);
            quoted = saturating_add(quoted, tax_quote, sat);
        }
        return std::max<int64_t>(1, quoted);
    };
    const auto full_consumption_subsidy = [&](const BundleOrder &order,
                                               int64_t units) {
        if (units <= 0) return int64_t{0};
        const int32_t cell = cohort_cell(order.slot);
        const VariantChoice &variant = _variants[order.variant_index];
        int64_t subsidy = 0;
        for (int32_t c = 0; c < variant.component_count; ++c) {
            const NeedComponent &component =
                _components[variant.component_begin + c];
            const int32_t rate = frozen_tax_rate(
                cell, CountryApi::TAX_CONSUMPTION,
                component.good_id);
            if (rate >= 0) continue;
            const int64_t quantity = mul_div_sat(
                units, component_quantity(order.slot, component), GOODS_SCALE, sat);
            const int64_t component_base = mul_div_sat(
                quantity,
                market_store().price[market_store().index(market, component.good_id)],
                GOODS_SCALE, sat);
            subsidy = saturating_add(subsidy,
                -expected_resolved_fiscal_transfer(
                    cell, CountryApi::TAX_CONSUMPTION,
                    component.good_id, component_base, quantity, sat), sat);
        }
        return subsidy;
    };
    // Settlement pays every consumption-lane subsidy out of the live fiscal
    // escrow, so the quotes handed to budget_orders have to draw down the same
    // lane budget in the same order. A quote that ignores the remaining escrow
    // bills a discount apply_fiscal_tax can no longer fund, and the cohort then
    // owes more cash than its budget reserved.
    thread_local std::vector<int32_t> subsidy_quota_cells;
    thread_local std::vector<int64_t> subsidy_quota_remaining;
    const auto apply_subsidy_quotes = [&](std::vector<BundleOrder> &orders) {
        if (!subsidy_settlement) return;
        subsidy_quota_cells.clear();
        subsidy_quota_remaining.clear();
        const auto quota_for_cell = [&](int32_t cell) -> int64_t & {
            for (size_t i = 0; i < subsidy_quota_cells.size(); ++i) {
                if (subsidy_quota_cells[i] == cell)
                    return subsidy_quota_remaining[i];
            }
            const size_t lane = static_cast<size_t>(cell) *
                ACTIVE_TAX_KIND_COUNT + CountryApi::TAX_CONSUMPTION;
            subsidy_quota_cells.push_back(cell);
            subsidy_quota_remaining.push_back(lane < _fiscal_remaining.size()
                ? std::max<int64_t>(0, _fiscal_remaining[lane]) : 0);
            return subsidy_quota_remaining.back();
        };
        for (BundleOrder &order : orders) {
            const int32_t cell = cohort_cell(order.slot);
            if (cell < 0 || cell >= _cell_count.get() || order.desired_units <= 0)
                continue;
            int64_t allocated = 0;
            if (consumption_tax_active) {
                allocated = full_consumption_subsidy(
                    order, order.desired_units);
            }
            const int32_t pay = family_purchase_pay_factor_q16(order.slot);
            if (pay < Q16_ONE) {
                // Settlement discounts the pre-tax component base, so quoting
                // against the tax-inclusive price would promise more than the
                // family discount actually removes from the invoice.
                const int64_t gross = mul_div_sat(
                    order.desired_units, order.base_unit_price, GOODS_SCALE, sat);
                const int64_t family_request = mul_div_sat(
                    gross, Q16_ONE - pay, Q16_ONE, sat);
                const int64_t family_alloc = -expected_fiscal_transfer(
                    cell, CountryApi::TAX_CONSUMPTION,
                    family_request, -10000, sat);
                allocated = saturating_add(
                    allocated, family_alloc, sat);
            }
            if (allocated <= 0) continue;
            int64_t &quota = quota_for_cell(cell);
            allocated = std::min(allocated, quota);
            if (allocated <= 0) continue;
            quota -= allocated;
            // Floor the per-unit discount so the quoted order budget is never
            // lower than the net cash ultimately charged at settlement.
            order.quoted_subsidy_per_unit = mul_div_sat(
                allocated, GOODS_SCALE, order.desired_units, sat);
            order.unit_price = std::max<int64_t>(
                0, saturating_sub(order.unit_price,
                                  order.quoted_subsidy_per_unit, sat));
        }
    };
    const auto is_survival_food_need = [&](const Need &need) {
        return need.stable_id >= 0 &&
            need.stable_id < static_cast<int32_t>(_survival_food_need_mask.size()) &&
            _survival_food_need_mask[need.stable_id] != 0;
    };
    // Any complete food sub-basket keeps a cohort alive, so the price-blind
    // survival floor only belongs to baskets near the cheapest in-stock
    // price level (price / reference). A basket priced above
    // FOOD_SUBSTITUTE_RATIO_Q16 times that loses the floor and its demand
    // shrinks in proportion, so its spending stays bounded instead of a
    // runaway protein price draining every household into the merchant.
    constexpr int64_t FOOD_SUBSTITUTE_RATIO_Q16 = 4 * Q16_ONE;
    thread_local std::vector<int64_t> food_need_price_index_q16;
    food_need_price_index_q16.assign(_needs.size(), 0);
    int64_t cheapest_food_index_q16 = 0;
    for (int32_t need_index = 0;
         need_index < static_cast<int32_t>(_needs.size()); ++need_index) {
        const Need &need = _needs[need_index];
        if (!is_survival_food_need(need)) continue;
        int64_t best = 0;
        for (int32_t v = 0; v < need.variant_count; ++v) {
            const int32_t variant_id = need.variant_begin + v;
            if (variant_score_cache[variant_id] <= 0) continue;
            const VariantChoice &variant = _variants[variant_id];
            bool in_stock = true;
            for (int32_t c = 0; c < variant.component_count && in_stock; ++c) {
                const int32_t good = _components[variant.component_begin + c].good_id;
                in_stock = market_store().stock[market_store().index(market, good)] >
                    production_input_floor[good];
            }
            if (!in_stock) continue;
            const int64_t index = std::max<int64_t>(1, mul_div_sat(
                variant_price_cache[variant_id], Q16_ONE,
                std::max<int64_t>(1, variant.reference_unit_price), sat));
            if (best == 0 || index < best) best = index;
        }
        food_need_price_index_q16[need_index] = best;
        if (best > 0 && (cheapest_food_index_q16 == 0 || best < cheapest_food_index_q16))
            cheapest_food_index_q16 = best;
    }
    static const bool diag_no_substitute = pk::runtime_switch_value(pk::RuntimeSwitch::PK_DIAG_NO_FOOD_SUBSTITUTE) != nullptr;
    const int64_t food_substitute_cap_q16 = !diag_no_substitute && cheapest_food_index_q16 > 0
        ? mul_div_sat(cheapest_food_index_q16, FOOD_SUBSTITUTE_RATIO_Q16, Q16_ONE, sat)
        : 0;
    static const bool family_good_cache_disabled = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_FAMILY_GOOD_CACHE_DISABLE);
        return value && std::strcmp(value, "1") == 0;
    }();
    thread_local std::vector<int32_t> household_family_good_factors;
    // Military v1 (design §5.1): needs listed in a profession's
    // state_supplied_need_ids are furnished in kind by Military. They never
    // enter market purchase; their satisfaction is written from the per-cell
    // ration satisfaction right after clearing, so a ration shortfall still
    // hits the survival dimension (and thus morale and starvation deaths).
    const bool has_state_supplied_needs = _state_supplied_need_columns != 0;
    thread_local std::vector<int64_t> cohort_ration_filled;
    thread_local std::vector<uint8_t> cohort_has_ration_needs;
    if (has_state_supplied_needs) {
        cohort_ration_filled.assign(cohort_count, 0);
        cohort_has_ration_needs.assign(cohort_count, 0);
    }
    for (int32_t local = 0; local < cohort_count; ++local) {
        const int32_t slot = slots[local];
        const uint32_t signature_id = population_store().signature_id[slot];
        if (signature_id >= _signatures.size()) {
            error = "cohort_signature_invalid";
            return false;
        }
        const Signature &signature = _signatures[signature_id];
        const Plan &plan = _plans[signature.plan_id];
        const int64_t population = std::max<int64_t>(0, population_store().population[slot]);
        if (population <= 0) continue;
        const bool ration_cohort = has_state_supplied_needs &&
            profession_is_state_service_only(signature.profession_id);
        // 订单准备不修改家族/人口，缓存只覆盖当前 cohort，换 cohort 即清空。
        if (!family_good_cache_disabled)
            household_family_good_factors.assign(_good_ids.size(), -1);
        for (int32_t n = 0; n < plan.need_count; ++n) {
            const int32_t need_index = plan.need_begin + n;
            const Need &need = _needs[need_index];
            // Military v1 (design §5.1): a ration need is supplied in kind.
            // Skip its purchase order entirely, but keep its welfare target so
            // the satisfaction ratio still carries the ration shortfall into
            // the survival dimension. Its filled units come from the per-cell
            // ration satisfaction written after clearing.
            if (ration_cohort && profession_need_is_state_supplied(
                    signature.profession_id, need.stable_id)) {
                int8_t &ration_available = satisfaction_need_available_cache[need_index];
                if (ration_available < 0)
                    ration_available = satisfaction_need_available(need, market) ? 1 : 0;
                int64_t ration_target = 0;
                if (ration_available != 0 && need_environment_cache[need_index] > 0) {
                    const int64_t ethnicity_factor = _ethnicity_need_factor_q16[
                        static_cast<size_t>(signature.ethnicity_id) *
                            _need_ids.size() + need.stable_id];
                    if (ethnicity_factor > 0) {
                        ration_target = saturating_mul(saturating_mul(
                            population, need.base_qty_per_person, sat),
                            std::max(1, _epoch_days.get()), sat);
                        ration_target = mul_div_sat(ration_target,
                            need_environment_cache[need_index],
                            Q16_ONE, sat);
                        ration_target = std::max<int64_t>(1, mul_div_sat(
                            ration_target, ethnicity_factor, Q16_ONE, sat));
                    }
                }
                // Welfare target only. `desired_units` stays 0 so clearing,
                // budgeting and fallback never see this need.
                need_states.push_back({local, need_index, 0, 0, 0, ration_target});
                if (ration_target > 0)
                    cohort_has_ration_needs[static_cast<size_t>(local)] = 1;
                continue;
            }
            // Frozen-sample approximation: calculate the whole market cycle
            // from the cohort/price/environment state captured at sample_day.
            const int64_t survival_required = survival_required_units(
                slot, need.stable_id, _epoch_days.get(), market_environment, sat);
            const bool survival_food = is_survival_food_need(need);
            if (survival_food) {
                cohort_food_required[local] = saturating_add(
                    cohort_food_required[local], survival_required, sat);
            } else if (need.stable_id == _survival_clothing_need_stable_id) {
                cohort_clothing_required[local] = saturating_add(
                    cohort_clothing_required[local], survival_required, sat);
            }
            std::array<int64_t, MAX_VARIANTS_PER_NEED> cohort_variant_scores{};
            int64_t base_score_sum = 0;
            int64_t score_sum = 0;
            for (int32_t v = 0; v < need.variant_count; ++v) {
                const int32_t variant_id = need.variant_begin + v;
                if (approximation_apply &&
                    approximation_variant_active[variant_id] == 0) continue;
                const int64_t base_score = std::max<int64_t>(
                    0, variant_score_cache[variant_id]);
                if (base_score <= 0 &&
                    population <=
                        (std::numeric_limits<int64_t>::max() >> 20)) {
                    cohort_variant_scores[v] = 0;
                    continue;
                }
                base_score_sum = saturating_add(
                    base_score_sum, base_score, sat);
                int64_t score = mul_div_sat(
                    base_score,
                    family_variant_preference_factor_q16(slot, variant_id, sat,
                        family_good_cache_disabled ? nullptr : household_family_good_factors.data()),
                    Q16_ONE, sat);
                score = mul_div_sat(score, interpolate_household_wealth_lut(
                    cohort_wealth_ratio_q16[local],
                    _variants[variant_id].wealth_lut_q16, sat),
                    Q16_ONE, sat);
                score = mul_div_sat(score, household_threshold_activation_q16(
                    cohort_savings_months_q16[local],
                    _variants[variant_id].savings_threshold_months_q16, sat),
                    Q16_ONE, sat);
                cohort_variant_scores[v] = std::max<int64_t>(0, score);
                score_sum = saturating_add(
                    score_sum, cohort_variant_scores[v], sat);
            }
            // A normative target is independent of wealth, shelf stock,
            // price elasticity and savings-gated variant preferences. Keep an
            // unlocked need in welfare even when it creates no purchase order.
            int64_t living_target = 0;
            int8_t &living_available = satisfaction_need_available_cache[need_index];
            if (living_available < 0)
                living_available = satisfaction_need_available(need, market) ? 1 : 0;
            if (living_available != 0 && need_environment_cache[need_index] > 0) {
                const int64_t ethnicity_factor = _ethnicity_need_factor_q16[
                    static_cast<size_t>(signature.ethnicity_id) * _need_ids.size() + need.stable_id];
                if (ethnicity_factor > 0) {
                    living_target = saturating_mul(saturating_mul(
                        population, need.base_qty_per_person, sat), std::max(1, _epoch_days.get()), sat);
                    living_target = mul_div_sat(living_target,
                        need_environment_cache[need_index], Q16_ONE, sat);
                    living_target = std::max<int64_t>(1, mul_div_sat(
                        living_target, ethnicity_factor, Q16_ONE, sat));
                }
            }
            if (score_sum <= 0) {
                if (living_target > 0)
                    need_states.push_back({local, need_index, 0, 0, 0, living_target});
                continue;
            }
            int64_t ordinary_desired = desired_need_units(
                slot, need_index, _epoch_days.get(), need_environment_cache[need_index],
                need_composite_cache[need_index], sat);
            if (base_score_sum > 0) {
                ordinary_desired = mul_div_sat(
                    ordinary_desired, score_sum, base_score_sum, sat);
            }
            int64_t survival_floor = survival_required;
            if (survival_food && food_substitute_cap_q16 > 0) {
                const int64_t index = food_need_price_index_q16[need_index];
                if (index <= 0) {
                    survival_floor = 0;
                } else if (index > food_substitute_cap_q16) {
                    // Calorie substitution: a food basket above N× the
                    // cheapest in-stock option loses both the survival floor
                    // and ordinary demand so households buy the cheap staple
                    // instead of draining savings into runaway protein.
                    survival_floor = 0;
                    ordinary_desired = 0;
                }
            }
            const int64_t desired = std::max(ordinary_desired, survival_floor);
            if (desired <= 0) {
                if (living_target > 0)
                    need_states.push_back({local, need_index, 0, 0, 0, living_target});
                continue;
            }
            const int32_t state_index = static_cast<int32_t>(need_states.size());
            need_states.push_back({local, need_index, desired, 0, 0, living_target});
            cohort_desired[local] = saturating_add(cohort_desired[local], desired, sat);
            int64_t prefix_score = 0;
            int64_t allocated = 0;
            for (int32_t v = 0; v < need.variant_count; ++v) {
                const int32_t variant_id = need.variant_begin + v;
                if (approximation_apply &&
                    approximation_variant_active[variant_id] == 0) continue;
                prefix_score = saturating_add(
                    prefix_score, cohort_variant_scores[v], sat);
                const int64_t next = mul_div_sat(desired, prefix_score, score_sum, sat);
                const int64_t units = std::max<int64_t>(0, next - allocated);
                allocated = next;
                if (units > 0) {
                    const int64_t base_price =
                        variant_price_cache[variant_id];
                    primary_orders.push_back({local, slot, state_index, variant_id,
                                              need.priority, units, 0, 0,
                                              household_quote(slot, variant_id,
                                                  base_price),
                                              base_price, 0});
                }
            }
            ++result.processed_needs;
            result.processed_variants += need.variant_count;
        }
    }
    auto retained_begin = [&](int32_t owner_slot, int32_t good_id) {
        return std::lower_bound(
            _owner_retained_outputs.begin(), _owner_retained_outputs.end(),
            std::pair<int32_t, int32_t>{owner_slot, good_id},
            [](const OwnerRetainedOutput &entry, const std::pair<int32_t, int32_t> &key) {
                return std::pair<int32_t, int32_t>{entry.owner_slot, entry.good_id} < key;
        });
    };
    auto record_in_kind_value = [&](int32_t owner_slot, int32_t good_id,
                                    int32_t building_group, int64_t quantity) {
        if (quantity <= 0 || owner_slot < 0 || good_id < 0 ||
            good_id >= market_store().good_count.get() ||
            owner_slot >= static_cast<int32_t>(population_store().active.size()) ||
            population_store().active[owner_slot] == 0) return;
        const int32_t page = owner_slot / COHORT_PAGE_SIZE;
        if (page < 0 || page >= static_cast<int32_t>(population_store().page_cell.size())) return;
        const int32_t cell = population_store().page_cell[page];
        if (cell < 0 || cell >= static_cast<int32_t>(market_store().cell_to_market.size())) return;
        const int32_t market = market_store().cell_to_market[cell];
        if (market < 0 || market >= market_store().market_count.get()) return;
        const int64_t price = market_store().price[market_store().index(market, good_id)];
        const int64_t value = mul_div_sat(quantity, price, GOODS_SCALE, sat);
        population_store().epoch_in_kind_income.write_scalar(owner_slot, saturating_add(
            population_store().epoch_in_kind_income[owner_slot], value, sat), market_mutation_sink());
        if (building_group >= 0) {
            result.building_in_kind_credits.push_back({building_group, value});
        }
        result.retained_consumed_by_good[good_id] = saturating_add(
            result.retained_consumed_by_good[good_id], quantity, sat);
        const int64_t food_eq = food_equivalent(good_id, quantity);
        result.food_access_eq = saturating_add(result.food_access_eq, food_eq, sat);
        if (food_eq > 0) ++result.food_access_events;
        record_food_access(cell, food_eq);
    };
    for (BundleOrder &order : primary_orders) {
        const VariantChoice &variant = _variants[order.variant_index];
        int64_t retained_capacity = order.desired_units;
        for (int32_t c = 0; c < variant.component_count; ++c) {
            const NeedComponent &component = _components[variant.component_begin + c];
            int64_t quantity = 0;
            auto found = retained_begin(order.slot, component.good_id);
            while (found != _owner_retained_outputs.end() &&
                   found->owner_slot == order.slot &&
                   found->good_id == component.good_id) {
                quantity = saturating_add(quantity, found->quantity, sat);
                ++found;
            }
            retained_capacity = std::min(retained_capacity, mul_div_sat(
                quantity, GOODS_SCALE,
                std::max<int64_t>(1, component_quantity(order.slot, component)), sat));
        }
        if (retained_capacity <= 0) continue;
        for (int32_t c = 0; c < variant.component_count; ++c) {
            const NeedComponent &component = _components[variant.component_begin + c];
            int64_t remaining = mul_div_sat(
                retained_capacity, component_quantity(order.slot, component),
                GOODS_SCALE, sat);
            auto found = retained_begin(order.slot, component.good_id);
            while (remaining > 0 && found != _owner_retained_outputs.end() &&
                   found->owner_slot == order.slot &&
                   found->good_id == component.good_id) {
                const int64_t used = std::min(remaining, found->quantity);
                found->quantity -= used;
                remaining -= used;
                record_in_kind_value(order.slot, component.good_id,
                                     found->building_group, used);
                ++found;
            }
            const int64_t used = mul_div_sat(
                retained_capacity, component_quantity(order.slot, component),
                GOODS_SCALE, sat) - remaining;
            result.retained_output_consumed = saturating_add(
                result.retained_output_consumed, used, sat);
        }
        need_states[order.need_index].filled_units = saturating_add(
            need_states[order.need_index].filled_units, retained_capacity, sat);
        order.desired_units -= retained_capacity;
    }
    // Exact plan variants consume retained output first. Any remaining
    // producer-retained food then acts as emergency calories across the three
    // survival food needs; preference still affects ordinary satisfaction, but
    // a hunter or fisher can live from the food it physically produced.
    for (int32_t local = 0; local < cohort_count; ++local) {
        int64_t food_filled = 0;
        for (const NeedState &state : need_states) {
            if (state.local_cohort != local) continue;
            const int32_t stable_need = _needs[state.need_index].stable_id;
            if (stable_need < 0 ||
                stable_need >= static_cast<int32_t>(
                    _survival_food_need_mask.size()) ||
                _survival_food_need_mask[stable_need] == 0) continue;
            food_filled = saturating_add(food_filled, state.filled_units, sat);
        }
        int64_t remaining = std::max<int64_t>(0, mul_div_sat(
            cohort_food_required[local], _survival_production_target_q16,
            Q16_ONE, sat) - food_filled);
        if (remaining <= 0) continue;
        auto entry = std::lower_bound(
            _owner_retained_outputs.begin(), _owner_retained_outputs.end(), slots[local],
            [](const OwnerRetainedOutput &value, int32_t owner_slot) {
                return value.owner_slot < owner_slot;
            });
        while (remaining > 0 && entry != _owner_retained_outputs.end() &&
               entry->owner_slot == slots[local]) {
            if (entry->good_id >= 0 &&
                entry->good_id < static_cast<int32_t>(_survival_food_good_mask.size()) &&
                _survival_food_good_mask[entry->good_id] != 0) {
                const int64_t used = std::min(remaining, entry->quantity);
                entry->quantity -= used;
                remaining -= used;
                record_in_kind_value(slots[local], entry->good_id,
                                     entry->building_group, used);
                cohort_subsistence_food_filled[local] = saturating_add(
                    cohort_subsistence_food_filled[local], used, sat);
                result.retained_output_consumed = saturating_add(
                    result.retained_output_consumed, used, sat);
            }
            ++entry;
        }
    }

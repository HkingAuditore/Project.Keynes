    auto physical_input_quantity = [&](int64_t effective,
                                       const InputCandidate &candidate) -> int64_t {
        int64_t physical = mul_div_sat(
            effective, Q16_ONE, candidate.efficiency_q16, _saturation_count);
        if (mul_div_sat(physical, candidate.efficiency_q16, Q16_ONE,
                        _saturation_count) < effective)
            physical = saturating_add(physical, 1, _saturation_count);
        return physical;
    };
    auto resource_capacity_scale_q16 = [&](const ResourceAmount &item,
                                           int32_t resource_cell,
                                           int64_t base) -> int64_t {
        if (base <= 0) return Q16_ONE;
        const int64_t available = available_resource_amount(item, resource_cell);
        int64_t scale = std::clamp<int64_t>(mul_div_sat(
            available, Q16_ONE, base, _saturation_count), 0, Q16_ONE);
        if (item.mode == 0 && resource_is_renewable(item.resource_id)) {
            int64_t density_q16 = resource_stock_density_q16(
                item.resource_id, resource_cell);
            if (_resource_safe_harvest_q16.get() <= 0 &&
                item.resource_id >= 0 && item.resource_id <
                    static_cast<int32_t>(_resource_ecology_capacity.size())) {
                const int64_t capacity = _resource_ecology_capacity[
                    static_cast<size_t>(item.resource_id)];
                if (capacity > 0) {
                    int64_t sat = 0;
                    // 目录已将生态容量转换为 GOODS_SCALE 单位，不能重复缩放。
                    const int64_t fixed_capacity = capacity;
                    if (fixed_capacity > 0) {
                        const int64_t remaining = std::max<int64_t>(0,
                            available_resource_amount(item, resource_cell));
                        density_q16 = static_cast<int64_t>(std::clamp<int64_t>(
                            mul_div_sat(remaining, Q16_ONE, fixed_capacity, sat),
                            0, Q16_ONE));
                    }
                }
            }
            // Availability and ecological density are independent natural
            // factors. Multiplying them preserves both losses; taking the
            // minimum would discard one of the constraints whenever the other
            // factor is smaller.
            scale = mul_div_sat(scale, density_q16, Q16_ONE,
                                _saturation_count);
        }
        // Keep a positive probe for a positive but sub-Q16 stock ratio. The
        // later integer quantity and stock checks remain authoritative.
        if (available > 0 && scale == 0) scale = 1;
        return scale;
    };
    // Soft inputs are optional productivity upgrades. Their purchase policy
    // depends on the concrete building group (output price, scale, owner
    // count, and local market), not merely on the catalog input edge. Cache by
    // (building group, input edge) so one profitable producer cannot force its
    // tool decision onto every other producer in the cell.
    thread_local std::unordered_map<uint64_t, int8_t> soft_input_policy;
    soft_input_policy.clear();
    soft_input_policy.reserve(static_cast<size_t>(std::max(16, end - begin)) * 2);
    auto input_purchase_scale_q16 = [&](const ProductionInput &input,
                                        int64_t output_scale_q16,
                                        bool soft_purchase_enabled) -> int64_t {
        const int64_t required = std::clamp<int64_t>(input.required_q16, 0, Q16_ONE);
        if (required <= 0) return 0;
        if (required < Q16_ONE && !soft_purchase_enabled) return 0;
        return std::clamp<int64_t>(output_scale_q16, 0, Q16_ONE);
    };
    auto scaled_input_quantity = [&](int64_t full_physical,
                                     int64_t purchase_scale_q16) -> int64_t {
        purchase_scale_q16 = std::clamp<int64_t>(purchase_scale_q16, 0, Q16_ONE);
        if (full_physical <= 0 || purchase_scale_q16 <= 0) return 0;
        const int64_t numerator = saturating_mul(
            full_physical, purchase_scale_q16, _saturation_count);
        return std::max<int64_t>(1, saturating_add(
            numerator, Q16_ONE - 1, _saturation_count) / Q16_ONE);
    };
    auto select_input_candidate = [&](const ProductionInput &input,
                                      bool require_stock,
                                      int64_t effective_required,
                                      int32_t output_factor_q16 = Q16_ONE) -> int32_t {
        int32_t best = -1;
        int64_t best_capacity_q16 = -1;
        int64_t best_cold_cover = -1;
        int64_t best_effective_price = std::numeric_limits<int64_t>::max();
        for (int32_t c = input.candidate_begin;
             c < input.candidate_begin + input.candidate_count; ++c) {
            const InputCandidate &candidate = _building_input_candidates[c];
            // Empty-shelf discovery must not admit trade-only locked SKUs
            // (metal tools while iron is locked). Stocked goods remain usable.
            if (!good_input_candidate_available(cell, candidate.good_id, true))
                continue;
            const int64_t stock = market_store().stock[
                market_store().index(market, candidate.good_id)];
            if (require_stock && stock <= 0) continue;
            int64_t capacity_q16 = Q16_ONE;
            if (require_stock && effective_required > 0) {
                const int64_t physical_required = effective_production_input_quantity(
                    cell, candidate.good_id,
                    physical_input_quantity(effective_required, candidate),
                    _saturation_count, output_factor_q16);
                capacity_q16 = physical_required > 0 ? std::min<int64_t>(
                    Q16_ONE, mul_div_sat(
                        stock, Q16_ONE, physical_required, _saturation_count)) : Q16_ONE;
            }
            const int64_t unit_physical = effective_production_input_quantity(
                cell, candidate.good_id,
                physical_input_quantity(GOODS_SCALE, candidate),
                _saturation_count, output_factor_q16);
            const int64_t effective_price = goods_cost(market_store().price[market_store().index(market, candidate.good_id)], unit_physical, _saturation_count);
            // Empty-shelf substitutes must not rank by ghost ceiling prices
            // alone. Prefer the good whose preferred producer can already
            // cover hard inputs locally (knapping when flint is stocked).
            const int64_t cold_cover = (!require_stock && stock <= 0)
                ? startup_producer_hard_input_cover_q16(
                    cell, candidate.good_id, _saturation_count)
                : Q16_ONE;
            if (capacity_q16 > best_capacity_q16 ||
                (capacity_q16 == best_capacity_q16 &&
                 cold_cover > best_cold_cover) ||
                (capacity_q16 == best_capacity_q16 &&
                 cold_cover == best_cold_cover &&
                 (effective_price < best_effective_price ||
                  (effective_price == best_effective_price &&
                   (best < 0 || candidate.good_id <
                    _building_input_candidates[best].good_id))))) {
                best = c;
                best_capacity_q16 = capacity_q16;
                best_cold_cover = cold_cover;
                best_effective_price = effective_price;
            }
        }
        return best;
    };
    auto soft_input_purchase_allowed = [&](const BuildingGroupConstRef &group,
                                           const BuildingType &type,
                                           int32_t input_index) -> bool {
        const int32_t global_input = type.input_begin + input_index;
        if (global_input < 0 || group.index < 0) return false;
        const uint64_t cache_key =
            (static_cast<uint64_t>(static_cast<uint32_t>(group.index)) << 32) |
            static_cast<uint32_t>(global_input);
        auto cached_it = soft_input_policy.find(cache_key);
        if (cached_it != soft_input_policy.end()) return cached_it->second != 0;
        int8_t cached = -1;
        const ProductionInput &input = _building_inputs[global_input];
        const int64_t required = std::clamp<int64_t>(input.required_q16, 0, Q16_ONE);
        if (required <= 0 || required >= Q16_ONE) {
            soft_input_policy.emplace(cache_key, 1);
            return true;
        }
        const int64_t building_days = saturating_mul(
            std::max<int64_t>(1, group.count), std::max(1, _epoch_days.get()),
            _saturation_count);
        const int64_t effective = saturating_mul(
            building_days, std::max<int64_t>(0, input.quantity),
            _saturation_count);
        const int32_t selected = select_input_candidate(
            input, false, effective, group.output_factor_q16);
        if (selected < 0) {
            soft_input_policy.emplace(cache_key, 0);
            return false;
        }
        const InputCandidate &candidate = _building_input_candidates[selected];
        const int64_t physical_input = effective_production_input_quantity(
            group.cell, candidate.good_id,
            physical_input_quantity(effective, candidate),
            _saturation_count, group.output_factor_q16);
        const int64_t input_base_cost = goods_cost(
            physical_input,
            market_store().price[market_store().index(market, candidate.good_id)],
            _saturation_count);
        const TransactionQuote input_quote = quote_transaction(
            group.cell, candidate.good_id, input_base_cost, false, true,
            _saturation_count, physical_input);
        const int64_t input_cost = std::max<int64_t>(
            0, input_quote.buyer_outlay);
        const int64_t marginal_bonus_q16 =
            soft_input_marginal_bonus_q16(type, required);
        int64_t marginal_output_value = 0;
        for (int32_t output_index = 0; output_index < type.output_count;
             ++output_index) {
            const GoodAmount &output = _building_outputs[
                type.output_begin + output_index];
            const int64_t full_output = effective_building_output_quantity(
                group, output.good_id, output.quantity, Q16_ONE,
                building_days, _saturation_count);
            const int64_t incremental_output = mul_div_sat(
                full_output, marginal_bonus_q16, Q16_ONE, _saturation_count);
            if (incremental_output <= 0) continue;
            const size_t output_market_index = market_store().index(
                market, output.good_id);
            const int64_t output_price = std::max<int64_t>(0,
                market_store().price[output_market_index]);

            // Owner retention is a current-period demand signal and is settled
            // before the remaining output enters merchant procurement.
            int64_t retained_increment = 0;
            const int32_t owner_signature = group.owner_signature_id;
            if (owner_signature >= 0 && owner_signature <
                    static_cast<int32_t>(_signatures.size()) &&
                retention_signature_stamp[owner_signature] ==
                    retention_generation) {
                const int32_t owner_index =
                    retention_owner_by_signature[owner_signature];
                const int32_t lane = owner_index >= 0
                    ? retention_lane(static_cast<size_t>(owner_index),
                        output.good_id) : -1;
                if (lane >= 0 && lane < static_cast<int32_t>(
                        retention_targets.size())) {
                    const int64_t remaining = std::max<int64_t>(0,
                        retention_targets[lane] - retention_used[lane]);
                    const int64_t retained_base = std::min(full_output, remaining);
                    retained_increment = std::min(incremental_output,
                        std::max<int64_t>(0, remaining - retained_base));
                }
            }
            int64_t expected_revenue = goods_cost(
                retained_increment, output_price, _saturation_count);

            const int64_t market_increment = std::max<int64_t>(0,
                incremental_output - retained_increment);
            if (market_increment > 0) {
                const int32_t signal = market_signal_index(
                    group.cell, output.good_id);
                const int64_t prior_sellable = signal >= 0 && signal <
                        static_cast<int32_t>(
                            _epoch_previous_producer_sellable.size())
                    ? std::max<int64_t>(0,
                        _epoch_previous_producer_sellable[signal]) : 0;
                const int64_t prior_merchant_sold = signal >= 0 && signal <
                        static_cast<int32_t>(
                            _epoch_previous_producer_merchant_sold.size())
                    ? std::clamp<int64_t>(
                        _epoch_previous_producer_merchant_sold[signal],
                        0, prior_sellable) : 0;
                // A new producer has no revealed channel mix yet; preserve the
                // normal merchant quote for its first expected sale.
                const int64_t merchant_share_q16 = prior_sellable > 0
                    ? mul_div_sat(prior_merchant_sold, Q16_ONE,
                        prior_sellable, _saturation_count)
                    : Q16_ONE;
                const int32_t output_signal = market_signal_index(
                    group.cell, output.good_id);
                const int32_t output_flow = trade_flow_index(
                    group.cell, output.good_id, false);
                const int64_t target = merchant_inventory_target(
                    market, output.good_id, output_signal,
                    output_signal >= 0 ? _market_signals.realized_withdrawal_ema[
                        output_signal] : 0,
                    output_flow >= 0 ? _trade_flows.export_ema[output_flow] : 0,
                    full_output, _saturation_count);
                const int32_t buy_factor = effective_merchant_buy_factor_q16(
                    market, output.good_id, target,
                    market_store().stock[output_market_index], _saturation_count);
                const int64_t merchant_unit_price = mul_div_sat(
                    output_price, buy_factor, Q16_ONE, _saturation_count);
                const int64_t merchant_quantity = mul_div_sat(
                    market_increment, merchant_share_q16, Q16_ONE,
                    _saturation_count);
                const int64_t supported_quantity = std::max<int64_t>(0,
                    market_increment - merchant_quantity);
                const int64_t support_unit_price = mul_div_sat(
                    output_price, 1, PRODUCER_SUPPORT_PRICE_DENOMINATOR,
                    _saturation_count);
                expected_revenue = saturating_add(expected_revenue,
                    saturating_add(
                        goods_cost(merchant_quantity, merchant_unit_price,
                            _saturation_count),
                        goods_cost(supported_quantity, support_unit_price,
                            _saturation_count), _saturation_count),
                    _saturation_count);
            }
            marginal_output_value = saturating_add(
                marginal_output_value, expected_revenue, _saturation_count);
        }
        cached = marginal_output_value > input_cost ? 1 : 0;
        soft_input_policy.emplace(cache_key, cached);
        return cached != 0;
    };
    auto desired_scale_for_group = [&](BuildingGroupConstRef group,
                                       const BuildingType &type,
                                       bool apply_climate) -> int64_t {
        const int64_t owner_demand = saturating_mul(
            group.count, type.owner_slots_per_building, _saturation_count);
        int64_t scale = owner_demand > 0 ? std::min<int64_t>(Q16_ONE, mul_div_sat(
            group.filled_owner, Q16_ONE, owner_demand, _saturation_count)) : 0;
        const int32_t group_index = static_cast<int32_t>(group.index);
        const int64_t planned_capacity_q16 = !apply_climate && group_index >= 0 &&
                group_index < static_cast<int32_t>(
                    _building_planned_capacity_before_climate_q16.size())
            ? _building_planned_capacity_before_climate_q16[group_index]
            : group.planned_utilization_q16;
        scale = std::min<int64_t>(scale, planned_capacity_q16);
        const int64_t building_days = saturating_mul(
            group.count, std::max(1, _epoch_days.get()), _saturation_count);
        for (int32_t i = 0; i < type.input_count; ++i) {
            const ProductionInput &item = _building_inputs[type.input_begin + i];
            if (select_input_candidate(item, false, saturating_mul(
                    building_days, item.quantity, _saturation_count)) < 0) {
                // Soft shortage does not cut objective activity; hard does.
                if (std::clamp<int64_t>(item.required_q16, 0, Q16_ONE) >= Q16_ONE)
                    scale = 0;
            }
        }
        if (apply_climate) {
            scale = mul_div_sat(scale,
                std::clamp<int64_t>(group.last_climate_capacity_q16, 0, Q16_ONE),
                Q16_ONE, _saturation_count);
        }
        return std::clamp<int64_t>(scale, 0, Q16_ONE);
    };
    thread_local std::vector<int32_t> quoted_input_candidates;
    thread_local std::vector<int64_t> quoted_input_quantities;
    thread_local std::vector<std::pair<int32_t, int64_t>> quoted_good_totals;
    struct InputPolicyBill {
        int32_t good = -1;
        int32_t rate = 0;
        int32_t mode = CountryApi::TAX_MODE_PERCENT_BP;
        int64_t quantity = 0;
        GoodsBill bill;
    };
    thread_local std::vector<InputPolicyBill> input_policy_bills;
    input_policy_bills.resize(std::max<size_t>(1, _building_inputs.size()));
    size_t input_policy_count = 0;
    bool observe_price_ceiling = !market_store().price_ceilings[market].empty();
    for (int32_t good = 0; good < market_store().good_count.get() && !observe_price_ceiling; ++good)
        observe_price_ceiling = int64_t(market_store().price[market_store().index(market, good)]) * 5 >=
                                int64_t(PRICE_NUMERIC_GUARD_MAX) * 4;
    thread_local std::vector<int32_t> ceiling_input_candidates;
    thread_local std::vector<int64_t> ceiling_input_quantities;
    auto quote_group_inputs = [&](BuildingGroupConstRef group,
                                  const BuildingType &type,
                                  int64_t output_scale_q16,
                                  bool require_stock,
                                  std::vector<int32_t> *selected_out,
                                  std::vector<int64_t> *quantities_out) -> int64_t {
        int64_t total_cost = 0;
        input_policy_count = 0;
        const int64_t building_days = saturating_mul(
            group.count, std::max(1, _epoch_days.get()), _saturation_count);
        output_scale_q16 = std::clamp<int64_t>(output_scale_q16, 0, Q16_ONE);
        quoted_good_totals.clear();
        if (selected_out != nullptr) selected_out->assign(type.input_count, -1);
        if (quantities_out != nullptr) quantities_out->assign(type.input_count, 0);
        for (int32_t input_index = 0; input_index < type.input_count; ++input_index) {
            const ProductionInput &item = _building_inputs[type.input_begin + input_index];
            const int64_t purchase_scale_q16 = input_purchase_scale_q16(
                item, output_scale_q16,
                soft_input_purchase_allowed(group, type, input_index));
            if (purchase_scale_q16 <= 0) continue;
            const int64_t effective = saturating_mul(
                building_days, item.quantity, _saturation_count);
            const int32_t selected = select_input_candidate(
                item, require_stock, effective, group.output_factor_q16);
            if (selected < 0) {
                // Soft tools are optional: missing stock skips the buy and
                // leaves throughput to soft_efficiency. Hard inputs abort.
                const int64_t required = std::clamp<int64_t>(
                    item.required_q16, 0, Q16_ONE);
                if (required >= Q16_ONE)
                    return std::numeric_limits<int64_t>::max();
                continue;
            }
            const InputCandidate &candidate = _building_input_candidates[selected];
            int64_t qty = scaled_input_quantity(
                effective_production_input_quantity(cell, candidate.good_id,
                    physical_input_quantity(effective, candidate),
                    _saturation_count, group.output_factor_q16), purchase_scale_q16);
            if (selected_out != nullptr) (*selected_out)[input_index] = selected;
            if (quantities_out != nullptr) (*quantities_out)[input_index] = qty;
            if (require_stock && qty > 0) {
                auto total = std::find_if(
                    quoted_good_totals.begin(), quoted_good_totals.end(),
                    [&](const std::pair<int32_t, int64_t> &entry) {
                        return entry.first == candidate.good_id;
                    });
                if (total == quoted_good_totals.end()) {
                    quoted_good_totals.push_back({candidate.good_id, qty});
                    total = quoted_good_totals.end() - 1;
                } else {
                    total->second = saturating_add(
                        total->second, qty, _saturation_count);
                }
                const int64_t stock = market_store().stock[
                    market_store().index(market, candidate.good_id)];
                if (total->second > stock) {
                    const int64_t required = std::clamp<int64_t>(
                        item.required_q16, 0, Q16_ONE);
                    if (required >= Q16_ONE)
                        return std::numeric_limits<int64_t>::max();
                    // Soft: buy only the residual shelf; do not ceiling
                    // objective activity on tool scarcity.
                    const int64_t prior = total->second - qty;
                    const int64_t available = std::max<int64_t>(0, stock - prior);
                    qty = available;
                    total->second = prior + qty;
                    if (quantities_out != nullptr)
                        (*quantities_out)[input_index] = qty;
                    if (qty <= 0) {
                        if (selected_out != nullptr)
                            (*selected_out)[input_index] = -1;
                        continue;
                    }
                }
            }
            const int32_t rate = frozen_tax_rate(cell,
                CountryApi::TAX_TRANSACTION, candidate.good_id);
            const int32_t mode = frozen_tax_mode(cell,
                CountryApi::TAX_TRANSACTION, candidate.good_id);
            size_t policy = 0;
            while (policy < input_policy_count &&
                   (input_policy_bills[policy].good != candidate.good_id ||
                    input_policy_bills[policy].rate != rate ||
                    input_policy_bills[policy].mode != mode))
                ++policy;
            if (policy == input_policy_count) {
                input_policy_bills[policy] = {candidate.good_id, rate, mode, 0, {}};
                ++input_policy_count;
            }
            input_policy_bills[policy].quantity = saturating_add(
                input_policy_bills[policy].quantity, qty, _saturation_count);
            input_policy_bills[policy].bill.add(qty,
                market_store().price[market_store().index(market, candidate.good_id)], _saturation_count);
        }
        for (size_t policy = 0; policy < input_policy_count; ++policy) {
            const InputPolicyBill &bill = input_policy_bills[policy];
            const TransactionQuote quote = quote_transaction(cell, bill.good,
                bill.bill.total(_saturation_count), false, true,
                _saturation_count, bill.quantity);
            total_cost = saturating_add(total_cost, quote.buyer_outlay, _saturation_count);
        }
        return std::max<int64_t>(0, total_cost);
    };
    auto group_input_cost_at_scale = [&](BuildingGroupConstRef group,
                                         const BuildingType &type,
                                         int64_t output_scale_q16,
                                         bool require_stock) -> int64_t {
        return quote_group_inputs(group, type, output_scale_q16, require_stock,
                                  nullptr, nullptr);
    };

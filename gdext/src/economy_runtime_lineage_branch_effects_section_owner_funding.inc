    // Quote the quantity this owner cohort could consume from its own output.
    // This is deliberately plan-based, so non-food workshops receive the same
    // in-kind treatment as farms when their goods are in the owner's basket.
    auto output_retention_target = [&](int32_t output_good) -> int64_t {
        if (output_good < 0 || output_good >= market_store().good_count.get() || owner_plan_id < 0 ||
            owner_plan_id >= static_cast<int32_t>(_plans.size())) return 0;
        auto &memo = living_cost_memo_state();
        static const bool retention_disabled = [] {
            const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_RETENTION_MEMO_DISABLE);
            return value && std::strcmp(value, "1") == 0;
        }();
        const bool reuse_retention = !retention_disabled && memo.owner == this && memo.depth > 0;
        const std::array<int64_t, 4> key{group.cell, owner_plan_id, owner_slots, output_good};
        const auto compute = [&](int64_t &sat) {
        const Plan &plan = _plans[owner_plan_id];
        int64_t target = 0;
        for (int32_t n = 0; n < plan.need_count; ++n) {
            const int32_t need_index = plan.need_begin + n;
            if (need_index < 0 || need_index >= static_cast<int32_t>(_needs.size())) continue;
            const Need &need = _needs[need_index];
            if (need.base_qty_per_person <= 0) continue;
            const int64_t env_q16 = sample_environment_curve(
                need.quantity_env_curve, owner_environment);
            int64_t desired = 0;
            // Keep the quote side-effect free and robust for partially
            // migrated catalogs: use the frozen per-person basket basis here
            // instead of requiring a live cohort demand preview.
            desired = mul_div_sat(saturating_mul(owner_slots,
                need.base_qty_per_person, sat), env_q16, Q16_ONE, sat);
            if (desired <= 0) continue;
            int64_t score_sum = 0;
            int64_t matching_score = 0;
            for (int32_t v = 0; v < need.variant_count; ++v) {
                const int32_t variant_id = need.variant_begin + v;
                if (variant_id < 0 || variant_id >= static_cast<int32_t>(_variants.size())) continue;
                const VariantChoice &variant = _variants[variant_id];
                int64_t score = mul_div_sat(variant.preference_q16,
                    sample_environment_curve(variant.preference_env_curve,
                        owner_environment), Q16_ONE, sat);
                score = std::max<int64_t>(1, score);
                score_sum = saturating_add(score_sum, score, sat);
                for (int32_t c = 0; c < variant.component_count; ++c) {
                    const int32_t component_index = variant.component_begin + c;
                    if (component_index < 0 || component_index >=
                            static_cast<int32_t>(_components.size())) continue;
                    if (_components[component_index].good_id == output_good)
                        matching_score = saturating_add(matching_score, score, sat);
                }
            }
            if (score_sum > 0 && matching_score > 0)
                target = saturating_add(target, mul_div_sat(desired,
                    matching_score, score_sum, sat), sat);
        }
        return std::max<int64_t>(0, target);
        };
        if (reuse_retention) {
            const auto found = memo.retention_targets.find(key);
            if (found != memo.retention_targets.end()) {
                static const bool verify = [] {
                    const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_ECONOMY_MEMO_VERIFY);
                    return value && std::strcmp(value, "1") == 0;
                }();
                if (verify) {
                    int64_t reference_sat = 0;
                    const int64_t reference = compute(reference_sat);
                    if (reference != found->second.first || reference_sat != found->second.second) {
                        std::fprintf(stderr, "[owner-retention-memo-mismatch] cell=%d plan=%d good=%d\n",
                            group.cell, owner_plan_id, output_good);
                        std::abort();
                    }
                }
                sat += found->second.second;
                EconomyCostProbe::record("owner_retention.reused", _current_day.get(), 0.0, 1);
                return found->second.first;
            }
        }
        const int64_t saturation_before = sat;
        const int64_t target = compute(sat);
        if (reuse_retention)
            memo.retention_targets.emplace(key, std::make_pair(target, sat - saturation_before));
        EconomyCostProbe::record("owner_retention.computed", _current_day.get(), 0.0, 1);
        return target;
    };
    if (quote_trace) add_quote_section(quote_sections.setup_ms, quote_setup_started);
    thread_local std::vector<int32_t> quoted_input_candidates;
    quoted_input_candidates.clear();
    quoted_input_candidates.reserve(static_cast<size_t>(std::max(0, type.input_count)));
    // The first output pass already evaluates the per-output quantity at this
    // throughput scale; the fundable-output pass reuses it instead of running
    // the same climate/count math a second time.
    thread_local std::vector<int64_t> quoted_output_quantities;
    quoted_output_quantities.assign(
        static_cast<size_t>(std::max(0, type.output_count)), 0);
    const auto quote_input_scan_started = Clock::now();
    // Soft inputs are capped productivity bonuses on top of 100% bare output.
    // Track bare (1.0x) and tooled (1.0x + capped bonus) multipliers.
    int64_t soft_efficiency_bare_q16 = Q16_ONE;
    int64_t soft_tooled_bonus_sum_q16 = 0;
    bool has_soft_partial_input = false;
    for (int32_t i = 0; i < type.input_count; ++i) {
        const ProductionInput &input = _building_inputs[type.input_begin + i];
        const int64_t required = std::clamp<int64_t>(input.required_q16, 0, Q16_ONE);
        int32_t best_candidate = -1;
        int64_t best_raw_capacity = -1;
        int64_t best_cost = std::numeric_limits<int64_t>::max();
        for (int32_t c = input.candidate_begin;
             c < input.candidate_begin + input.candidate_count; ++c) {
            const InputCandidate &candidate = _building_input_candidates[c];
            if (!good_input_candidate_available(group.cell, candidate.good_id, true)) continue;
            const int64_t raw = saturating_mul(group.count, input.quantity, sat);
            const int64_t physical_numerator = saturating_add(
                saturating_mul(raw, Q16_ONE, sat),
                std::max<int32_t>(0, candidate.efficiency_q16) - 1, sat);
            const int64_t physical = effective_production_input_quantity(
                group.cell, candidate.good_id,
                physical_numerator / std::max<int32_t>(1, candidate.efficiency_q16),
                sat, group.output_factor_q16);
            const int32_t idx = market_store().index(market, candidate.good_id);
            const int64_t stock = std::max<int64_t>(0, market_store().stock[idx]);
            const int64_t raw_capacity = physical > 0
                ? std::clamp<int64_t>(mul_div_sat(stock, Q16_ONE,
                    physical, sat), 0, Q16_ONE) : Q16_ONE;
            const int64_t cost = mul_div_sat(physical, market_store().price[idx],
                GOODS_SCALE, sat);
            if (raw_capacity > best_raw_capacity || (raw_capacity == best_raw_capacity &&
                (cost < best_cost || (cost == best_cost && (best_candidate < 0 ||
                    candidate.good_id < _building_input_candidates[best_candidate].good_id))))) {
                best_candidate = c;
                best_raw_capacity = raw_capacity;
                best_cost = cost;
            }
        }
        if (best_candidate < 0) {
            if (required >= Q16_ONE) { quote.prospective_scale_q16 = 0;
                quote.executable_capacity_q16 = 0; return quote; }
            quoted_input_candidates.push_back(-1);
            continue;
        }
        if (required >= Q16_ONE) {
            scale = std::min(scale, best_raw_capacity);
        } else if (required > 0) {
            has_soft_partial_input = true;
            const int64_t marginal_bonus =
                soft_input_marginal_bonus_q16(type, required);
            soft_tooled_bonus_sum_q16 = saturating_add(
                soft_tooled_bonus_sum_q16,
                mul_div_sat(marginal_bonus, best_raw_capacity, Q16_ONE, sat),
                sat);
        }
        quoted_input_candidates.push_back(best_candidate);
    }
    const int64_t soft_efficiency_tooled_q16 =
        clamp_soft_productivity_bonus_q16(soft_tooled_bonus_sum_q16);
    if (quote_trace)
        add_quote_section(quote_sections.input_scan_ms, quote_input_scan_started);
    auto purchase_input_cost_at_scale = [&](int64_t eval_scale,
                                            bool buy_soft) -> int64_t {
        int64_t total = 0;
        for (int32_t i = 0; i < type.input_count; ++i) {
            const ProductionInput &input = _building_inputs[type.input_begin + i];
            const int32_t best_candidate = i < static_cast<int32_t>(
                quoted_input_candidates.size()) ? quoted_input_candidates[i] : -1;
            const int64_t required = std::clamp<int64_t>(input.required_q16, 0, Q16_ONE);
            if (best_candidate < 0 || required <= 0) continue;
            if (required < Q16_ONE && !buy_soft) continue;
            const InputCandidate &candidate = _building_input_candidates[best_candidate];
            const int64_t raw = saturating_mul(group.count, input.quantity, sat);
            const int64_t physical_numerator = saturating_add(
                saturating_mul(raw, Q16_ONE, sat),
                std::max<int32_t>(0, candidate.efficiency_q16) - 1, sat);
            const int64_t physical = effective_production_input_quantity(
                group.cell, candidate.good_id,
                physical_numerator / std::max<int32_t>(1, candidate.efficiency_q16),
                sat, group.output_factor_q16);
            const int64_t purchase_scale = std::clamp<int64_t>(eval_scale, 0, Q16_ONE);
            const int64_t quantity = mul_div_sat(physical, purchase_scale,
                Q16_ONE, sat);
            const int64_t base_cost = mul_div_sat(quantity,
                market_store().price[market_store().index(market, candidate.good_id)],
                GOODS_SCALE, sat);
            const int32_t transaction_rate = frozen_tax_rate(
                group.cell, CountryApi::TAX_TRANSACTION,
                candidate.good_id);
            const int64_t input_transfer = expected_fiscal_transfer(
                group.cell, CountryApi::TAX_TRANSACTION, base_cost,
                transaction_rate, sat);
            total = saturating_add(total,
                std::max<int64_t>(0, saturating_add(base_cost, input_transfer, sat)),
                sat);
        }
        return total;
    };
    // Existing owners must fund the inputs production would actually buy at
    // the evaluated scale. Vacant lots skip this: employment/investment
    // validates sponsor capital on transfer. The owner cash headroom does not
    // depend on buy_soft/eval_scale, so it is resolved once per quote and
    // shared by the tooled and bare clamps instead of re-running
    // living_cost_for_signature for the same cell/signature twice.
    int64_t owner_cash_headroom = 0;
    bool owner_cash_headroom_ready = false;
    const auto owner_available_cash = [&]() -> int64_t {
        if (!owner_cash_headroom_ready) {
            owner_cash_headroom_ready = true;
            if (group.filled_owner > 0 && owner_slot >= 0) {
                const int64_t funds = std::max<int64_t>(0,
                    population_store().funds[owner_slot]);
                const int64_t people = std::max<int64_t>(1,
                    population_store().population[owner_slot]);
                const int64_t reserve = saturating_mul(saturating_mul(
                    living_cost_for_signature(group.cell,
                        group.owner_signature_id, -1, sat), people, sat), 30,
                    sat);
                owner_cash_headroom = std::max<int64_t>(0, funds - reserve);
            }
        }
        return owner_cash_headroom;
    };
    auto clamp_scale_to_owner_funds = [&](int64_t eval_scale,
                                          bool buy_soft) -> int64_t {
        if (group.filled_owner <= 0) return eval_scale;
        const int64_t purchase_bill = purchase_input_cost_at_scale(
            eval_scale, buy_soft);
        if (purchase_bill <= 0) return eval_scale;
        if (owner_slot < 0) return eval_scale;
        const auto clamp_headroom_started = Clock::now();
        const int64_t available = owner_available_cash();
        if (quote_trace)
            add_quote_section(quote_sections.clamp_headroom_ms,
                              clamp_headroom_started);
        return std::min(eval_scale, std::clamp<int64_t>(mul_div_sat(
            available, Q16_ONE, purchase_bill, sat), 0, Q16_ONE));
    };

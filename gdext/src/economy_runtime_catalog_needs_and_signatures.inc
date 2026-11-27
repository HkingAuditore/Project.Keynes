    _need_ids = catalog_need_ids;
    const std::vector<std::string> curve_ids = packed_strings(catalog, "environment_curve_ids");
    const std::vector<int32_t> curve_signals = packed_i32(catalog, "environment_curve_signal_ids");
    const std::vector<int32_t> curve_values = packed_i32(catalog, "environment_curve_values_q16");
    if (_need_ids.empty() || _need_ids.size() > 32 || curve_ids.size() != curve_signals.size() ||
        curve_values.size() != curve_ids.size() * ENV_CURVE_SAMPLES ||
        !unique_sorted(_need_ids, "need") || !unique_sorted(curve_ids, "environment_curve")) {
        error = "need_or_environment_curve_catalog_invalid";
        return false;
    }
    _survival_food_need_stable_ids.clear();
    for (const char *id : {"staple_food", "protein", "produce"}) {
        const auto found = std::lower_bound(_need_ids.begin(), _need_ids.end(), id);
        if (found == _need_ids.end() || *found != id) {
            error = std::string("survival_food_need_missing:") + id;
            return false;
        }
        _survival_food_need_stable_ids.push_back(
            static_cast<int32_t>(found - _need_ids.begin()));
    }
    _survival_food_need_mask.assign(_need_ids.size(), uint8_t{0});
    for (const int32_t stable_need : _survival_food_need_stable_ids)
        _survival_food_need_mask[stable_need] = 1;
    const auto clothing = std::lower_bound(_need_ids.begin(), _need_ids.end(), "clothing");
    if (clothing == _need_ids.end() || *clothing != "clothing") {
        error = "survival_clothing_need_missing:clothing";
        return false;
    }
    _survival_clothing_need_stable_id =
        static_cast<int32_t>(clothing - _need_ids.begin());
    _environment_curves.resize(curve_ids.size());
    for (size_t c = 0; c < curve_ids.size(); ++c) {
        if (curve_signals[c] < 0 || curve_signals[c] > 3) {
            error = "environment_curve_signal_invalid";
            return false;
        }
        _environment_curves[c].signal_id = curve_signals[c];
        for (int32_t k = 0; k < ENV_CURVE_SAMPLES; ++k) {
            _environment_curves[c].values_q16[k] = std::max(0, curve_values[c * ENV_CURVE_SAMPLES + k]);
        }
    }

    const std::vector<int32_t> plan_offsets = packed_i32(catalog, "plan_need_offsets");
    const std::vector<int32_t> need_stable = packed_i32(catalog, "need_stable_ids");
    const std::vector<int32_t> need_living_weights =
        packed_i32(catalog, "need_living_cost_weights_q16");
    // Satisfaction tier/weight columns are authored per global need id. An older
    // catalog that predates them classifies everything as basic at full weight,
    // which reproduces a plain per-need average.
    std::vector<int32_t> need_satisfaction_tiers =
        packed_i32(catalog, "need_satisfaction_tiers");
    std::vector<int32_t> need_satisfaction_weights =
        packed_i32(catalog, "need_satisfaction_weights_q16");
    if (need_satisfaction_tiers.empty())
        need_satisfaction_tiers.assign(_need_ids.size(), SAT_DIM_BASIC);
    if (need_satisfaction_weights.empty())
        need_satisfaction_weights.assign(_need_ids.size(),
                                         static_cast<int32_t>(Q16_ONE));
    if (need_satisfaction_tiers.size() != _need_ids.size() ||
        need_satisfaction_weights.size() != _need_ids.size()) {
        error = "need_satisfaction_columns_invalid";
        return false;
    }
    const std::vector<int32_t> need_priority = packed_i32(catalog, "need_priorities");
    const std::vector<int64_t> need_base = packed_i64(catalog, "need_base_qty_per_person");
    const std::vector<int32_t> need_wealth_elasticity = packed_i32(catalog, "need_wealth_elasticity_q16");
    const std::vector<int32_t> need_wealth_min = packed_i32(catalog, "need_wealth_min_q16");
    const std::vector<int32_t> need_wealth_max = packed_i32(catalog, "need_wealth_max_q16");
    const std::vector<int32_t> need_price_quantity_elasticity = packed_i32(
        catalog, "need_price_quantity_elasticity_q16");
    const std::vector<int32_t> need_price_quantity_floor = packed_i32(
        catalog, "need_price_quantity_floor_q16");
    const std::vector<int32_t> need_env = packed_i32(catalog, "need_quantity_env_curve_ids");
    const std::vector<int32_t> need_variant_offsets = packed_i32(catalog, "need_variant_offsets");
    const size_t need_count = need_stable.size();
    if (plan_offsets.size() != _plan_ids.size() + 1 || plan_offsets.front() != 0 ||
        plan_offsets.back() != static_cast<int32_t>(need_count) || need_priority.size() != need_count ||
        need_base.size() != need_count || need_wealth_elasticity.size() != need_count ||
        need_wealth_min.size() != need_count || need_wealth_max.size() != need_count ||
        need_price_quantity_elasticity.size() != need_count ||
        need_price_quantity_floor.size() != need_count ||
        need_env.size() != need_count ||
        need_living_weights.size() != _need_ids.size() ||
        need_variant_offsets.size() != need_count + 1 ||
        need_variant_offsets.front() != 0) {
        error = "market_v2_need_columns_invalid";
        return false;
    }
    const std::vector<int32_t> variant_preference = packed_i32(catalog, "variant_preference_q16");
    const std::vector<int32_t> variant_elasticity = packed_i32(catalog, "variant_price_elasticity_q16");
    std::vector<int32_t> variant_class_wealth_delta = packed_i32(
        catalog, "variant_class_wealth_elasticity_delta_q16");
    std::vector<int32_t> variant_class_threshold_factor = packed_i32(
        catalog, "variant_class_savings_threshold_factor_q16");
    const std::vector<int32_t> variant_env = packed_i32(catalog, "variant_preference_env_curve_ids");
    const std::vector<int32_t> variant_component_offsets = packed_i32(catalog, "variant_component_offsets");
    const size_t variant_count = variant_preference.size();
    if (variant_class_wealth_delta.empty())
        variant_class_wealth_delta.assign(variant_count, 0);
    if (variant_class_threshold_factor.empty())
        variant_class_threshold_factor.assign(variant_count, Q16_ONE);
    if (need_variant_offsets.back() != static_cast<int32_t>(variant_count) ||
        variant_elasticity.size() != variant_count || variant_env.size() != variant_count ||
        variant_class_wealth_delta.size() != variant_count ||
        variant_class_threshold_factor.size() != variant_count ||
        variant_component_offsets.size() != variant_count + 1 || variant_component_offsets.front() != 0) {
        error = "market_v2_variant_columns_invalid";
        return false;
    }
    const std::vector<int32_t> component_goods = packed_i32(catalog, "component_good_ids");
    const std::vector<int64_t> component_qty = packed_i64(catalog, "component_qty_per_need");
    if (variant_component_offsets.back() != static_cast<int32_t>(component_goods.size()) ||
        component_qty.size() != component_goods.size()) {
        error = "market_v2_component_columns_invalid";
        return false;
    }
    _plans.resize(_plan_ids.size());
    for (size_t p = 0; p < _plans.size(); ++p) {
        const int32_t begin = plan_offsets[p];
        const int32_t count = plan_offsets[p + 1] - begin;
        if (begin < 0 || count < 0 || count > MAX_NEEDS_PER_PLAN) {
            error = "plan_need_limit_exceeded";
            return false;
        }
        _plans[p] = {begin, count};
    }
    _needs.resize(need_count);
    for (size_t n = 0; n < need_count; ++n) {
        const int32_t variants_begin = need_variant_offsets[n];
        const int32_t variants_count = need_variant_offsets[n + 1] - variants_begin;
        if (need_stable[n] < 0 || need_stable[n] >= static_cast<int32_t>(_need_ids.size()) ||
            need_base[n] < 0 || need_wealth_min[n] < 0 || need_wealth_max[n] < need_wealth_min[n] ||
            need_price_quantity_elasticity[n] < 0 ||
            need_price_quantity_elasticity[n] > Q16_ONE * 4 ||
            need_price_quantity_floor[n] < 0 || need_price_quantity_floor[n] > Q16_ONE ||
            need_env[n] < -1 || need_env[n] >= static_cast<int32_t>(_environment_curves.size()) ||
            need_living_weights[need_stable[n]] < 0 ||
            need_living_weights[need_stable[n]] > Q16_ONE ||
            need_satisfaction_tiers[need_stable[n]] < 0 ||
            need_satisfaction_tiers[need_stable[n]] >= SAT_TIER_COUNT ||
            need_satisfaction_weights[need_stable[n]] < 0 ||
            need_satisfaction_weights[need_stable[n]] > Q16_ONE ||
            variants_count <= 0 || variants_count > MAX_VARIANTS_PER_NEED) {
            error = "market_v2_need_entry_invalid";
            return false;
        }
        _needs[n] = {need_stable[n], need_priority[n], variants_begin, variants_count,
                     need_base[n], need_wealth_elasticity[n], need_wealth_min[n],
                     need_wealth_max[n], need_price_quantity_elasticity[n],
                     need_price_quantity_floor[n], need_env[n],
                     need_living_weights[need_stable[n]],
                     need_satisfaction_tiers[need_stable[n]],
                     need_satisfaction_weights[need_stable[n]]};
        for (size_t anchor = 0; anchor < HOUSEHOLD_WEALTH_ANCHORS_Q16.size(); ++anchor) {
            _needs[n].wealth_lut_q16[anchor] = static_cast<int32_t>(
                std::clamp<int64_t>(pow_q16(
                    HOUSEHOLD_WEALTH_ANCHORS_Q16[anchor],
                    need_wealth_elasticity[n], _saturation_count),
                    0, std::numeric_limits<int32_t>::max()));
        }
    }
    _variants.resize(variant_count);
    for (size_t v = 0; v < variant_count; ++v) {
        const int32_t comp_begin = variant_component_offsets[v];
        const int32_t comp_count = variant_component_offsets[v + 1] - comp_begin;
        if (variant_preference[v] < 0 || variant_elasticity[v] < 0 ||
            variant_class_wealth_delta[v] < -Q16_ONE ||
            variant_class_wealth_delta[v] > Q16_ONE * 2 ||
            variant_class_threshold_factor[v] < 0 ||
            variant_class_threshold_factor[v] > Q16_ONE * 4 ||
            variant_env[v] < -1 || variant_env[v] >= static_cast<int32_t>(_environment_curves.size()) ||
            comp_count <= 0 || comp_count > MAX_COMPONENTS_PER_VARIANT) {
            error = "market_v2_variant_entry_invalid";
            return false;
        }
        int64_t reference_cost = 0;
        int64_t weighted_wealth_elasticity = 0;
        int32_t savings_threshold_months_q16 = 0;
        for (int32_t k = 0; k < comp_count; ++k) {
            const int32_t component = comp_begin + k;
            if (component_goods[component] < 0 || component_goods[component] >= static_cast<int32_t>(goods) ||
                component_qty[component] <= 0) {
                error = "market_v2_component_entry_invalid";
                return false;
            }
            const int64_t component_cost = mul_div_sat(
                component_qty[component], _good_default_price[component_goods[component]],
                GOODS_SCALE, _saturation_count);
            reference_cost = saturating_add(
                reference_cost, component_cost, _saturation_count);
            weighted_wealth_elasticity = saturating_add(
                weighted_wealth_elasticity, saturating_mul(
                    component_cost,
                    _good_household_wealth_elasticity_q16[component_goods[component]],
                    _saturation_count), _saturation_count);
            savings_threshold_months_q16 = std::max(
                savings_threshold_months_q16,
                _good_household_savings_threshold_months_q16[
                    component_goods[component]]);
        }
        _variants[v] = {comp_begin, comp_count, variant_preference[v], variant_elasticity[v],
                        variant_env[v], std::max<int64_t>(1, reference_cost)};
        const int32_t base_wealth_elasticity = reference_cost > 0
            ? static_cast<int32_t>(weighted_wealth_elasticity / reference_cost) : 0;
        _variants[v].wealth_elasticity_q16 = static_cast<int32_t>(
            std::clamp<int64_t>(
                static_cast<int64_t>(base_wealth_elasticity) +
                    variant_class_wealth_delta[v],
                -Q16_ONE, Q16_ONE * 2));
        _variants[v].savings_threshold_months_q16 = static_cast<int32_t>(
            std::clamp<int64_t>(mul_div_sat(
                savings_threshold_months_q16,
                variant_class_threshold_factor[v], Q16_ONE,
                _saturation_count), 0, Q16_ONE * 480));
        for (size_t anchor = 0; anchor < HOUSEHOLD_WEALTH_ANCHORS_Q16.size(); ++anchor) {
            _variants[v].wealth_lut_q16[anchor] = static_cast<int32_t>(
                std::clamp<int64_t>(pow_q16(
                    HOUSEHOLD_WEALTH_ANCHORS_Q16[anchor],
                    _variants[v].wealth_elasticity_q16, _saturation_count),
                    Q16_ONE / 16, Q16_ONE * 64));
        }
    }
    _components.resize(component_goods.size());
    for (size_t c = 0; c < component_goods.size(); ++c) {
        _components[c] = {component_goods[c], component_qty[c]};
    }
    // 未解锁项可以提前跳过，但必须保留旧路径的饱和计数。保守界同时
    // 覆盖 signed i32 的价格和消费系数；超界目录仍执行原来的价格计算。
    constexpr int64_t preview_safe_quantity = GOODS_SCALE * Q16_ONE;
    for (VariantChoice &variant : _variants) {
        const int64_t component_limit = preview_safe_quantity /
            std::max(1, variant.component_count);
        variant.preview_price_saturation_free = true;
        for (int32_t c = 0; c < variant.component_count; ++c) {
            if (_components[variant.component_begin + c].qty_per_need >
                    component_limit) {
                variant.preview_price_saturation_free = false;
                break;
            }
        }
    }
    // Plans repeat market-side need formulas. Identify exact equivalents once,
    // including ordered components (rounding) and every basis input. This is
    // derived catalog metadata, never persisted or used as actor authority.
    _preview_need_basis_source.resize(_needs.size());
    // 偏好/环境不同的候选也可能拥有完全相同的价格基础；保留组件顺序及数量。
    std::map<std::vector<int64_t>, int32_t> variant_price_sources;
    for (int32_t v = 0; v < static_cast<int32_t>(_variants.size()); ++v) {
        VariantChoice &variant = _variants[v];
        std::vector<int64_t> key{variant.reference_unit_price,
            variant.price_elasticity_q16, variant.component_count};
        for (int32_t c = 0; c < variant.component_count; ++c) {
            const NeedComponent &component = _components[variant.component_begin + c];
            key.insert(key.end(), {component.good_id, component.qty_per_need});
        }
        variant.price_basis_source = variant_price_sources.emplace(std::move(key), v).first->second;
    }
    std::map<std::vector<int64_t>, int32_t> preview_basis_sources;
    for (int32_t n = 0; n < static_cast<int32_t>(_needs.size()); ++n) {
        const Need &need = _needs[n];
        std::vector<int64_t> key{need.quantity_env_curve,
            need.price_quantity_elasticity_q16, need.price_quantity_floor_q16,
            need.variant_count};
        for (int32_t v = 0; v < need.variant_count; ++v) {
            const VariantChoice &variant = _variants[need.variant_begin + v];
            key.insert(key.end(), {variant.preference_q16,
                variant.price_elasticity_q16, variant.preference_env_curve,
                variant.reference_unit_price, variant.component_count});
            for (int32_t c = 0; c < variant.component_count; ++c) {
                const NeedComponent &component = _components[variant.component_begin + c];
                key.insert(key.end(), {component.good_id, component.qty_per_need});
            }
        }
        _preview_need_basis_source[n] = preview_basis_sources.emplace(
            std::move(key), n).first->second;
    }
    // Derive one canonical food-equivalent coefficient from the authored
    // survival plan. A component quantity is the number of goods subunits
    // required for one standard need unit, so one such unit contributes
    // GOODS_SCALE equivalent food subunits. This keeps production, trade and
    // household clearing on the same numeric basis without a second content
    // table.
    _good_food_equivalent_q16.assign(goods, 0);
    _survival_food_good_mask.assign(goods, uint8_t{0});
    _survival_clothing_good_mask.assign(goods, uint8_t{0});
    for (const Need &need : _needs) {
        const bool survival_food_need = need.stable_id >= 0 &&
            need.stable_id < static_cast<int32_t>(
                _survival_food_need_mask.size()) &&
            _survival_food_need_mask[need.stable_id] != 0;
        const bool survival_clothing_need =
            need.stable_id == _survival_clothing_need_stable_id;
        if (!survival_food_need && !survival_clothing_need) continue;
        for (int32_t v = 0; v < need.variant_count; ++v) {
            const VariantChoice &variant = _variants[need.variant_begin + v];
            if (survival_food_need && variant.component_count != 1) {
                error = "survival_food_variant_must_have_one_component:" +
                    _need_ids[static_cast<size_t>(need.stable_id)];
                return false;
            }
            const NeedComponent &component = _components[variant.component_begin];
            if (survival_food_need) {
                if (component.qty_per_need <= 0) {
                    error = "survival_food_component_quantity_invalid:" +
                        _need_ids[static_cast<size_t>(need.stable_id)];
                    return false;
                }
                const int64_t coefficient = std::max<int64_t>(1,
                    (GOODS_SCALE * Q16_ONE) / component.qty_per_need);
                const int32_t good = component.good_id;
                if (_good_food_equivalent_q16[static_cast<size_t>(good)] != 0 &&
                    _good_food_equivalent_q16[static_cast<size_t>(good)] != coefficient) {
                    error = "survival_food_good_quantity_inconsistent:" +
                        _good_ids[static_cast<size_t>(good)];
                    return false;
                }
                _good_food_equivalent_q16[static_cast<size_t>(good)] =
                    static_cast<int32_t>(std::clamp<int64_t>(coefficient, 1, Q16_ONE * 4));
                _survival_food_good_mask[static_cast<size_t>(good)] = 1;
            }
            if (survival_clothing_need) {
                for (int32_t c = 0; c < variant.component_count; ++c) {
                    const int32_t good = _components[variant.component_begin + c].good_id;
                    if (good >= 0 && good < static_cast<int32_t>(_survival_clothing_good_mask.size()))
                        _survival_clothing_good_mask[static_cast<size_t>(good)] = 1;
                }
            }
        }
    }
    if (std::none_of(_survival_food_good_mask.begin(),
                     _survival_food_good_mask.end(), [](uint8_t value) {
                         return value != 0;
                     })) {
        error = "survival_food_good_catalog_empty";
        return false;
    }

    _food_equivalent_goods.clear();
    for (int32_t good = 0; good < goods; ++good) {
        if (_good_food_equivalent_q16[static_cast<size_t>(good)] > 0)
            _food_equivalent_goods.push_back(good);
    }
    const std::vector<int32_t> sig_prof = packed_i32(catalog, "signature_profession_ids");
    const std::vector<int32_t> sig_eth = packed_i32(catalog, "signature_ethnicity_ids");
    const std::vector<int32_t> sig_plan = packed_i32(catalog, "signature_plan_ids");
    const std::vector<int64_t> sig_birth = packed_i64(catalog, "signature_birth_rate_q32");
    const std::vector<int64_t> sig_death = packed_i64(catalog, "signature_death_rate_q32");
    std::vector<int64_t> sig_sat_weight = packed_i64(catalog, "signature_satisfaction_birth_weight_q16");
    const size_t sig_count = sig_prof.size();
    if (sig_count == 0 || sig_eth.size() != sig_count || sig_plan.size() != sig_count ||
        sig_birth.size() != sig_count || sig_death.size() != sig_count) {
        error = "signature_table_size_mismatch";
        return false;
    }
    if (sig_sat_weight.empty()) sig_sat_weight.assign(sig_count, Q16_ONE);
    if (sig_sat_weight.size() != sig_count) {
        error = "signature_satisfaction_weight_size_mismatch";
        return false;
    }
    // Per-signature composite weights. A profession that authors nothing emits
    // -1 in every slot and inherits the profile default.
    const std::vector<int32_t> sig_dimension_weights = packed_i32(
        catalog, "signature_satisfaction_dimension_weights_q16");
    const bool has_dimension_weights = !sig_dimension_weights.empty();
    if (has_dimension_weights &&
        sig_dimension_weights.size() !=
            sig_count * static_cast<size_t>(SAT_DIM_COUNT)) {
        error = "signature_satisfaction_dimension_weight_size_mismatch";
        return false;
    }
    _signatures.resize(sig_count);
    for (size_t i = 0; i < sig_count; ++i) {
        if (sig_prof[i] < 0 || sig_prof[i] >= static_cast<int32_t>(_profession_ids.size()) ||
            sig_eth[i] < 0 || sig_eth[i] >= static_cast<int32_t>(_ethnicity_ids.size()) ||
            sig_plan[i] < 0 || sig_plan[i] >= static_cast<int32_t>(_plans.size()) ||
            sig_birth[i] < 0 || sig_death[i] < 0) {
            error = "signature_entry_invalid";
            return false;
        }
        _signatures[i] = {sig_prof[i], sig_eth[i], sig_plan[i], sig_birth[i], sig_death[i],
                          sig_sat_weight[i], {}};
        Signature &signature = _signatures[i];
        int64_t weight_total = 0;
        for (int32_t dim = 0; dim < SAT_DIM_COUNT; ++dim) {
            const int32_t authored = has_dimension_weights
                ? sig_dimension_weights[i * static_cast<size_t>(SAT_DIM_COUNT) +
                                        static_cast<size_t>(dim)]
                : -1;
            const int32_t weight = authored < 0
                ? _satisfaction_default_weights_q16[static_cast<size_t>(dim)]
                : authored;
            if (weight > Q16_ONE) {
                error = "signature_satisfaction_dimension_weight_out_of_range";
                return false;
            }
            signature.satisfaction_weights_q16[static_cast<size_t>(dim)] = weight;
            weight_total += weight;
        }
        if (weight_total <= 0) {
            error = "signature_satisfaction_dimension_weights_empty";
            return false;
        }
    }
    _merchant_profession_id = -1;
    for (size_t p = 0; p < _profession_ids.size(); ++p) {
        if (_profession_ids[p] == _merchant_profession_stable_id) {
            _merchant_profession_id = static_cast<int32_t>(p);
            break;
        }
    }
    if (_merchant_profession_id < 0) {
        error = "merchant_profession_missing:" + _merchant_profession_stable_id;
        return false;
    }
    // The unemployed profession is optional: catalogs that predate the explicit
    // unemployment model simply leave it unresolved (-1), and the employment pass
    // falls back to the derived population - owner - employee accounting. When it
    // is present it enables the persistent unemployed-pool signatures.
    _unemployed_profession_id = -1;
    for (size_t p = 0; p < _profession_ids.size(); ++p) {
        if (_profession_ids[p] == _unemployed_profession_stable_id) {
            _unemployed_profession_id = static_cast<int32_t>(p);
            break;
        }
    }
    // Build the dense (profession, ethnicity) -> signature lookup. Deterministic:
    // signatures are the profession x ethnicity cartesian product, so at most one
    // entry per (profession, ethnicity). Any unfilled cell stays -1.
    {
        const size_t n_prof = _profession_ids.size();
        const size_t n_eth = _ethnicity_ids.size();
        _signature_by_profession_ethnicity.assign(n_prof * n_eth, -1);
        for (size_t i = 0; i < _signatures.size(); ++i) {
            const int32_t prof = _signatures[i].profession_id;
            const int32_t eth = _signatures[i].ethnicity_id;
            if (prof < 0 || eth < 0 || static_cast<size_t>(prof) >= n_prof ||
                static_cast<size_t>(eth) >= n_eth) {
                error = "signature_profession_ethnicity_out_of_range";
                return false;
            }
            const size_t idx = static_cast<size_t>(prof) * n_eth + static_cast<size_t>(eth);
            if (_signature_by_profession_ethnicity[idx] < 0) {
                _signature_by_profession_ethnicity[idx] = static_cast<int32_t>(i);
            }
        }
    }
    _ethnicity_need_factor_q16 = packed_i32(catalog, "ethnicity_need_factor_q16");
    if (_ethnicity_need_factor_q16.empty()) {
        _ethnicity_need_factor_q16.assign(_ethnicity_ids.size() * _need_ids.size(), Q16_ONE);
    }    if (_ethnicity_need_factor_q16.size() != _ethnicity_ids.size() * _need_ids.size()) {
        error = "ethnicity_need_factor_size_mismatch";
        return false;
    }
    // Military v1: state buildings are owned by the reserved STATE_OWNER
    // signature. It resolves to the catalog's state-service signature of the
    // first ethnicity so the group key stays a real (profession, ethnicity)
    // pair that no live cohort occupies: state-service professions never enter
    // the unemployed pool, so no plan-driven cohort is ever born there, and the
    // payroll fill pass distributes owner seats over live population only.
    // Catalogs without a state-service profession leave it at -1 so state
    // buildings can never be built.

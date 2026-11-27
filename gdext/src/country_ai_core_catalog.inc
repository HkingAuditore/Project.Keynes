uint64_t country_ai_catalog_hash(const CountryAiCatalog &c) {
    uint64_t h = FNV_OFFSET;
    const auto mix = [&h](int64_t v) { h = fnv_u64(h, static_cast<uint64_t>(v)); };
    mix(c.schema); mix(static_cast<int64_t>(c.seed));
    mix(c.think_days); mix(c.strategy_days); mix(c.research_days); mix(c.tax_days);
    mix(c.colonize_days); mix(c.agenda_min_days); mix(c.agenda_inertia_bp);
    mix(c.decision_noise_bp); mix(c.research_budget_horizon_days);
    mix(c.research_min_share_bp); mix(c.research_max_share_bp);
    mix(c.research_tax_share_bp); mix(c.research_per_capita_budget);
    mix(c.research_essentials_floor_q16);
    mix(c.research_weight_threshold_bp); mix(c.research_max_enqueue_per_eval);
    mix(c.research_budget_change_bp); mix(c.research_frontier_visit_limit);
    mix(c.tax_kind_mask); mix(c.tax_step_bp); mix(c.tax_max_step_bp);
    mix(c.tax_deadband_q16); mix(c.satisfaction_floor_q16); mix(c.reserve_target_days);
    mix(c.reserve_floor_cash); mix(c.colonize_max_in_flight);
    mix(c.colonize_population_share_bp); mix(c.colonize_min_population);
    mix(c.colonize_vision_radius); mix(c.colonize_target_ring);
    mix(c.colonize_failure_cooldown_days); mix(c.colonize_min_reserve_days);
    mix(c.colonize_min_country_population); mix(c.colonize_min_population_per_cell);
    mix(c.colonize_essentials_floor_q16); mix(c.colonize_min_cell_value_q16);
    mix(c.colonize_cell_value_weight_bp);
    mix(c.research_load_full_q16); mix(c.research_load_zero_q16);
    mix(c.research_hungry_share_max_q16); mix(c.colonize_hungry_share_max_q16);
    mix(c.subsidy_food_rate_bp); mix(c.subsidy_on_hungry_share_q16);
    mix(c.subsidy_off_hungry_share_q16);
    for (const CountryAiAgendaDef &a : c.agendas) {
        mix(a.consideration_count);
        for (uint32_t i = 0; i < a.consideration_count; ++i) {
            const CountryAiCurve &curve = a.considerations[i];
            mix(curve.input); mix(curve.kind); mix(curve.x0); mix(curve.x1);
            mix(curve.y0_q16); mix(curve.y1_q16);
        }
        mix(a.research_share_bp); mix(a.expansion_slots); mix(a.tax_bias_bp);
        mix(a.satisfaction_floor_shift_q16); mix(a.era_focus);
    }
    mix(static_cast<int64_t>(c.personalities.size()));
    for (const CountryAiPersonality &p : c.personalities) {
        mix(static_cast<int64_t>(p.id_hash)); mix(p.weight); mix(p.risk_bp);
        for (int32_t v : p.agenda_bias_bp) mix(v);
        for (int32_t v : p.domain_affinity_bp) mix(v);
        for (int32_t v : p.tax_min_bp) mix(v);
        for (int32_t v : p.tax_max_bp) mix(v);
        for (int32_t v : p.tax_initial_bp) mix(v);
        for (int32_t v : p.family_pref) mix(v);
    }
    return h & 0x7fffffffffffffffull;
}

bool country_ai_validate_catalog(const CountryAiCatalog &c, std::string &error) {
    const auto fail = [&error](const char *code) { error = code; return false; };
    if (c.schema != COUNTRY_AI_SCHEMA) return fail("country_ai_schema_unsupported");
    if (c.think_days < 1 || c.strategy_days < 1 || c.research_days < 1 ||
        c.tax_days < 1 || c.colonize_days < 1)
        return fail("country_ai_cadence_invalid");
    if (c.personalities.empty() || c.personalities.size() > COUNTRY_AI_MAX_PERSONALITIES)
        return fail("country_ai_personalities_invalid");
    for (const CountryAiPersonality &p : c.personalities) {
        if (p.weight <= 0) return fail("country_ai_personality_weight_invalid");
        for (uint32_t k = 0; k < COUNTRY_AI_TAX_KIND_COUNT; ++k) {
            if (p.tax_min_bp[k] < -100000 || p.tax_max_bp[k] > 10000 ||
                p.tax_min_bp[k] > p.tax_max_bp[k])
                return fail("country_ai_tax_bounds_invalid");
        }
        for (int32_t v : p.domain_affinity_bp)
            if (v <= 0) return fail("country_ai_domain_affinity_invalid");
    }
    for (const CountryAiAgendaDef &a : c.agendas) {
        if (a.consideration_count > COUNTRY_AI_MAX_CONSIDERATIONS)
            return fail("country_ai_agenda_considerations_invalid");
        for (uint32_t i = 0; i < a.consideration_count; ++i) {
            if (a.considerations[i].input >= COUNTRY_AI_INPUT_COUNT ||
                a.considerations[i].kind >= COUNTRY_AI_CURVE_COUNT)
                return fail("country_ai_curve_invalid");
        }
        if (a.research_share_bp < 0 || a.research_share_bp > 10000)
            return fail("country_ai_research_share_invalid");
    }
    if (c.tax_step_bp <= 0 || c.tax_max_step_bp < c.tax_step_bp)
        return fail("country_ai_tax_step_invalid");
    if (c.research_max_enqueue_per_eval < 0 || c.research_max_enqueue_per_eval > 8)
        return fail("country_ai_research_enqueue_invalid");
    if (c.colonize_population_share_bp < 0 || c.colonize_population_share_bp > 10000)
        return fail("country_ai_colonize_share_invalid");
    if (c.research_load_full_q16 < 0 || c.research_load_zero_q16 <= c.research_load_full_q16)
        return fail("country_ai_research_load_invalid");
    const auto share_ok = [](int32_t v) { return v >= 0 && v <= COUNTRY_AI_Q16; };
    if (!share_ok(c.research_hungry_share_max_q16) || !share_ok(c.colonize_hungry_share_max_q16))
        return fail("country_ai_hungry_share_invalid");
    if (c.subsidy_food_rate_bp > 0 || c.subsidy_food_rate_bp < -100000 ||
        !share_ok(c.subsidy_on_hungry_share_q16) ||
        c.subsidy_off_hungry_share_q16 < 0 ||
        c.subsidy_off_hungry_share_q16 > c.subsidy_on_hungry_share_q16)
        return fail("country_ai_food_subsidy_invalid");
    return true;
}

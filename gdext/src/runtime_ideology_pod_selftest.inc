bool RuntimeIdeologyPodAuthority::self_test(std::string &error) {
    error.clear();
    // Shared multiplier maths first: both authorities read these, and a rounding
    // difference between them shows up as a replay mismatch weeks later rather
    // than as a wrong number here.
    {
        const int32_t one = static_cast<int32_t>(Q16_ONE);
        if (ideology_frozen_factor({}, 0) != one ||
            ideology_frozen_factor({static_cast<int32_t>(2 * Q16_ONE)}, 0) != 2 * one ||
            ideology_frozen_factor({one}, 3) != one ||
            ideology_frozen_factor({static_cast<int32_t>(100 * Q16_ONE)}, 0) != 4 * one) {
            error = "ideology_self_test_frozen_factor_failed"; return false;
        }
        if (ideology_scaled_daily(1000, one) != 1000 ||
            ideology_scaled_daily(1000, 2 * one) != 2000 ||
            ideology_scaled_daily(1000, 0) != 0 ||
            ideology_scaled_daily(0, 2 * one) != 0) {
            error = "ideology_self_test_scaled_daily_failed"; return false;
        }
        if (ideology_reroll_percent(50, one) != 50 ||
            ideology_reroll_percent(50, 2 * one) != 100 ||
            ideology_reroll_percent(50, 0) != 0 ||
            ideology_reroll_percent(400, 4 * one) != 400) {
            error = "ideology_self_test_reroll_percent_failed"; return false;
        }
    }
    // R8-3: the country RNG seed must depend on the WORLD, not only on the
    // handle. Before this the same country drew the same card sequence in every
    // game of the same map, which is a content defect rather than a parity one
    // (both authorities shared the bug, so parity could not see it).
    {
        constexpr uint64_t kHandle = 0x1ull << 32u;
        const uint64_t zero = runtime_ideology_country_rng_seed(kHandle, 0);
        const uint64_t a = runtime_ideology_country_rng_seed(kHandle, 1);
        const uint64_t b = runtime_ideology_country_rng_seed(kHandle, 2);
        if (a == b || a == zero || b == zero ||
            runtime_ideology_country_rng_seed(kHandle, 1) != a ||
            runtime_ideology_country_rng_seed(kHandle ^ 1u, 1) == a) {
            error = "ideology_self_test_world_seed_failed"; return false;
        }
    }
    RuntimeIdeologyPodCatalog catalog;
    catalog.country_catalog_hash = 77; catalog.class_hash = 88; catalog.class_count = 1;
    catalog.route_keys = {"cropland"};
    catalog.technology_count = 1; catalog.research_signal_count = 1; catalog.gate_count = 1;
    catalog.ideology_capacity = 4; catalog.spirit_capacity = 2; catalog.starting_points_q16 = Q16_ONE;
    catalog.point_population_weight_q16 = Q16_ONE;
    catalog.max_commands_per_slice = 2; catalog.max_transition_polls_per_slice = 1; catalog.max_active_visits_per_slice = 1;
    catalog.levels = {{0, 0}};
    for (int i = 0; i < 4; ++i) {
        RuntimeIdeologyPodDefinition d; d.level_begin = 0; d.level_count = 1; d.rarity_weight = i + 1;
        d.stance_begin = 0; d.stance_count = 1; d.support_threshold_q16 = {{-Q16_ONE, -Q16_ONE, -Q16_ONE}};
        catalog.definitions.push_back(d);
    }
    catalog.ideology_synergy_offsets = {0, 0, 0, 0, 0};
    RuntimeIdeologyPodClassStance stance; stance.class_index = 0; stance.stance_q16 = {{Q16_ONE, Q16_ONE, Q16_ONE}};
    catalog.class_stances.push_back(stance);
    RuntimeCountryPodSnapshot country;
    country.generation = 1; country.catalog_hash = 77; country.bootstrapped = true; country.country_count = 1;
    country.technology_count = 1; country.technology_words = 1; country.research_signal_count = 1; country.research_signal_words = 1;
    country.country_active = {1}; country.country_generation = {3}; country.country_technologies = {1};
    country.country_discovered = {1}; country.country_pending_technologies = {0}; country.country_research_signals = {1};
    RuntimeIdeologyOpinionSnapshot opinion;
    opinion.revision = 1; opinion.class_hash = 88; opinion.country_count = 1; opinion.class_count = 1;
    const uint64_t handle = (3ull << 32u); opinion.country_handles = {handle}; opinion.country_generations = {3};
    opinion.population = {100}; opinion.funds = {0}; opinion.owner_employed = {0}; opinion.satisfaction_weighted = {0}; opinion.satisfaction_q16 = {0};
    // X6-a acceptance: only the population lane is doubled. The next
    // observation must pay 20 + 7 = 27 Q16, then apply the 0.5 opinion factor
    // because satisfaction is zero. The ledger is read directly so a helper
    // that happens to add the right total cannot hide a wrong term.
    {
        RuntimeIdeologyPodCatalog factor_catalog = catalog;
        factor_catalog.point_population_weight_q16 = Q16_ONE;
        factor_catalog.point_building_weight_q16 = Q16_ONE;
        factor_catalog.point_trade_weight_q16 = Q16_ONE;
        RuntimeIdeologyOpinionSnapshot factor_opinion = opinion;
        factor_opinion.revision = 1;
        factor_opinion.country_population = {100};
        factor_opinion.country_buildings_installed = {0};
        factor_opinion.country_trade_base_value = {0};
        factor_opinion.period_days = 1;
        factor_opinion.point_population_factor_q16 = {
            static_cast<int32_t>(2 * Q16_ONE)};
        RuntimeIdeologyPodAuthority factor_authority;
        RuntimeIdeologyPodPlan factor_plan;
        if (!factor_authority.configure(factor_catalog, error) ||
            !factor_authority.bootstrap(country, factor_opinion, error) ||
            !factor_authority.plan_day(0, country, factor_opinion, {},
                                       factor_plan, error) ||
            !factor_authority.commit_day(factor_plan, error)) {
            error = "ideology_self_test_x6a_baseline_failed";
            return false;
        }
        const int64_t before = factor_authority.snapshot()
            .countries[0].ideology_points_q16;
        factor_opinion.revision = 2;
        factor_opinion.country_population = {110};
        factor_opinion.country_buildings_installed = {7};
        if (!factor_authority.plan_day(1, country, factor_opinion, {},
                                       factor_plan, error) ||
            !factor_authority.commit_day(factor_plan, error)) {
            error = "ideology_self_test_x6a_accrual_failed";
            return false;
        }
        const auto &factor_row = factor_authority.snapshot().countries[0];
        const int64_t expected_gain = 27 * Q16_ONE / 2;
        if (factor_row.ledger.population_q16 != 20 * Q16_ONE ||
            factor_row.ledger.building_q16 != 7 * Q16_ONE ||
            factor_row.ledger.trade_q16 != 0 ||
            factor_row.ledger.gain_q16 != expected_gain ||
            factor_row.ideology_points_q16 - before != expected_gain) {
            error = "ideology_self_test_x6a_ledger_failed";
            return false;
        }
    }
    RuntimeIdeologyPodAuthority authority;
    if (!authority.configure(catalog, error) || !authority.bootstrap(country, opinion, error)) return false;
    RuntimeIdeologyOpinionSnapshot invalid = opinion; invalid.revision = 0;
    RuntimeIdeologyPodPlan plan;
    if (authority.plan_day(0, country, invalid, {}, plan, error)) { error = "ideology_self_test_revision_rejection_failed"; return false; }
    RuntimeCountryPodSnapshot stale_country = country;
    stale_country.country_generation[0] = 4;
    stale_country.generation = 2;
    RuntimeIdeologyOpinionSnapshot stale_opinion = opinion;
    stale_opinion.country_generations[0] = 4;
    stale_opinion.country_handles[0] = (4ull << 32u);
    if (authority.plan_day(0, stale_country, stale_opinion, {}, plan, error) ||
        error != "ideology_country_state_generation_mismatch") {
        error = "ideology_self_test_country_generation_rejection_failed";
        return false;
    }
    auto command = [&](uint64_t id, RuntimeIdeologyPodOpcode opcode, int32_t idea, int64_t value, int32_t priority) {
        RuntimeIdeologyPodCommand c; c.request_id = id; c.producer_id = 1; c.sequence = id; c.requested_day = 0; c.effective_day = 0;
        c.source_priority = priority; c.country_handle = handle; c.opcode = opcode; c.ideology_id = idea; c.value_q16 = value; return c;
    };
    auto grant = command(1, RuntimeIdeologyPodOpcode::GRANT_POINTS, -1, Q16_ONE, 2);
    auto gate = command(2, RuntimeIdeologyPodOpcode::SET_GATE, -1, 1, 1); gate.gate_id = 0;
    auto discover = command(3, RuntimeIdeologyPodOpcode::DISCOVER, 0, 0, 3);
    if (!authority.queue_command(discover, error) || !authority.queue_command(grant, error) || !authority.queue_command(gate, error)) return false;
    bool checked_opinion_continuation = false;
    do {
        if (!authority.plan_day(0, country, opinion, {}, plan, error) ||
            !authority.commit_day(plan, error)) return false;
        if (!plan.completed_day && !checked_opinion_continuation) {
            RuntimeIdeologyOpinionSnapshot changed_opinion = opinion;
            changed_opinion.revision = 2;
            RuntimeIdeologyPodPlan rejected_plan;
            if (authority.plan_day(0, country, changed_opinion, {},
                                   rejected_plan, error) ||
                error != "ideology_same_day_continuation_opinion_changed") {
                error = "ideology_self_test_opinion_continuation_rejection_failed";
                return false;
            }
            checked_opinion_continuation = true;
            error.clear();
        }
    } while (!plan.completed_day);
    if (!bit_get(authority.snapshot().countries[0].known_bits, 0) || !bit_get(authority.snapshot().countries[0].gate_bits, 0)) { error = "ideology_self_test_order_or_basic_opcode_failed"; return false; }
    auto open = command(4, RuntimeIdeologyPodOpcode::OPEN_OFFER, -1, 0, 0); open.effective_day = open.requested_day = 1;
    if (!authority.queue_command(open, error)) return false;
    do { if (!authority.plan_day(1, country, opinion, {}, plan, error) || !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
    if (authority.snapshot().countries[0].offer.active == 0) { error = "ideology_self_test_offer_failed"; return false; }
    auto choose = command(5, RuntimeIdeologyPodOpcode::CHOOSE_OFFER, -1, 0, 0); choose.effective_day = choose.requested_day = 2;
    choose.offer_generation = authority.snapshot().countries[0].offer.generation; choose.choice_index = 0;
    if (!authority.queue_command(choose, error)) return false;
    do { if (!authority.plan_day(2, country, opinion, {}, plan, error) || !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
    int32_t chosen = -1; for (int32_t id = 1; id < 4; ++id) if (bit_get(authority.snapshot().countries[0].known_bits, id)) { chosen = id; break; }
    if (chosen < 0) { error = "ideology_self_test_choose_failed"; return false; }
    auto equip = command(6, RuntimeIdeologyPodOpcode::EQUIP, chosen, 0, 0); equip.effective_day = equip.requested_day = 3;
    if (!authority.queue_command(equip, error)) return false;
    bool saw_deferred_intent = false;
    do {
        if (!authority.plan_day(3, country, opinion, {}, plan, error) || !authority.commit_day(plan, error)) return false;
        if (!plan.intents.empty()) {
            saw_deferred_intent = true;
            if ((plan.intents[0].flags & (RUNTIME_DOMAIN_INTENT_DEFERRED | RUNTIME_DOMAIN_INTENT_REQUIRES_ACK)) !=
                    (RUNTIME_DOMAIN_INTENT_DEFERRED | RUNTIME_DOMAIN_INTENT_REQUIRES_ACK)) {
                error = "ideology_self_test_intent_flags_failed"; return false;
            }
        }
    } while (!plan.completed_day);
    if (authority.snapshot().countries[0].ideas[chosen].location != RuntimeIdeologyPodLocation::INACTIVE ||
        authority.snapshot().pending_transitions.size() != 1 || !saw_deferred_intent) { error = "ideology_self_test_deferred_transition_failed"; return false; }
    const uint64_t intent_id = authority.snapshot().pending_transitions[0].intent_id;
    RuntimeDomainAck ack; ack.transaction_id = intent_id; ack.target_handle = handle; ack.target_generation = 3;
    ack.effective_day = 3;
    ack.domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT); ack.code = RuntimeDomainAckCode::OK;
    RuntimeDomainAck wrong_day_ack = ack;
    wrong_day_ack.effective_day = 4;
    if (authority.plan_day(4, country, opinion, {wrong_day_ack}, plan, error) ||
        error != "ideology_ack_effective_day_mismatch") {
        error = "ideology_self_test_ack_day_rejection_failed";
        return false;
    }
    do { if (!authority.plan_day(4, country, opinion, {ack}, plan, error) || !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
    if (authority.snapshot().countries[0].ideas[chosen].location != RuntimeIdeologyPodLocation::IDEOLOGY ||
        !authority.snapshot().pending_transitions.empty()) { error = "ideology_self_test_real_ack_failed"; return false; }
    auto add = command(7, RuntimeIdeologyPodOpcode::ADD_UNDERSTANDING, chosen, Q16_ONE, 0); add.effective_day = add.requested_day = 5;
    if (!authority.queue_command(add, error)) return false;
    do { if (!authority.plan_day(5, country, opinion, {}, plan, error) || !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
    auto promote = command(8, RuntimeIdeologyPodOpcode::PROMOTE, chosen, 0, 0); promote.effective_day = promote.requested_day = 6;
    if (!authority.queue_command(promote, error)) return false;
    do { if (!authority.plan_day(6, country, opinion, {}, plan, error) || !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
    auto unequip = command(9, RuntimeIdeologyPodOpcode::UNEQUIP, chosen, 0, 0); unequip.effective_day = unequip.requested_day = 7;
    if (!authority.queue_command(unequip, error)) return false;
    do { if (!authority.plan_day(7, country, opinion, {}, plan, error) || !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
    // Increment-only accrual: the first lane observation is a baseline, the
    // next pays delta-population * weight * opinion factor (satisfaction 0 -> 0.5).
    RuntimeIdeologyOpinionSnapshot grow = opinion;
    grow.revision = 5; grow.country_population = {100}; grow.country_buildings_installed = {0};
    grow.country_trade_base_value = {0}; grow.period_days = 1;
    do { if (!authority.plan_day(8, country, grow, {}, plan, error) || !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
    const int64_t points_before = authority.snapshot().countries[0].ideology_points_q16;
    grow.revision = 6; grow.country_population = {110};
    do { if (!authority.plan_day(9, country, grow, {}, plan, error) || !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
    if (authority.snapshot().countries[0].ideology_points_q16 - points_before != 5 * Q16_ONE ||
        authority.snapshot().countries[0].history_count != 1) {
        error = "ideology_self_test_point_accrual_failed"; return false;
    }
    auto reopen = command(10, RuntimeIdeologyPodOpcode::OPEN_OFFER, -1, 0, 0); reopen.effective_day = reopen.requested_day = 10;
    if (!authority.queue_command(reopen, error)) return false;
    do { if (!authority.plan_day(10, country, grow, {}, plan, error) || !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
    const uint32_t offer_generation = authority.snapshot().countries[0].offer.generation;
    const int64_t before_reroll = authority.snapshot().countries[0].ideology_points_q16;
    auto reroll = command(11, RuntimeIdeologyPodOpcode::REROLL_OFFER, -1, 0, 0); reroll.effective_day = reroll.requested_day = 11;
    reroll.offer_generation = offer_generation;
    if (!authority.queue_command(reroll, error)) return false;
    do { if (!authority.plan_day(11, country, grow, {}, plan, error) || !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
    if (authority.snapshot().countries[0].offer.active == 0 ||
        authority.snapshot().countries[0].offer.generation != offer_generation + 1u ||
        before_reroll - authority.snapshot().countries[0].ideology_points_q16 != Q16_ONE / 2) {
        error = "ideology_self_test_reroll_failed"; return false;
    }
    // X6-b: a free draw and a paid draw at the same state must consume the
    // exact same RNG path. Clone the authority after the reroll, close the
    // existing offer on both branches, then open both at the same global day.
    // The free grant is a command on an earlier day, while both OPEN_OFFER
    // commands settle on day 13; the free branch only decrements its row
    // counter, while the paid branch charges points.
    {
        auto close_offer = [](RuntimeIdeologyPodAuthority &target,
                              std::string &close_error) {
            // The only effect is removing the current offer. CHOOSE_OFFER is
            // unsuitable because it also mutates knowledge/understanding.
            // Restore-style reset through the public API would require a
            // serialized copy. The self-test runs inside this class, so direct
            // state access is intentional and keeps the test independent of
            // serialization.
            target._current.countries[0].offer.clear();
            target._current.state_hash = compute_state_hash(target._current);
            target._planned = target._current;
            target._plan_ready = false;
            close_error.clear();
            return true;
        };
        auto run_command = [&](RuntimeIdeologyPodAuthority &target,
                               RuntimeIdeologyPodOpcode opcode,
                               uint64_t request_id, int64_t target_day,
                               int64_t value,
                               RuntimeIdeologyPodPlan &day_plan,
                               std::string &day_error) {
            RuntimeIdeologyPodCommand next_command = command(
                request_id, opcode, -1, value, 0);
            next_command.effective_day = target_day;
            next_command.requested_day = target_day;
            if (!target.queue_command(next_command, day_error)) return false;
            do {
                if (!target.plan_day(target_day, country, grow, {}, day_plan,
                                     day_error) ||
                    !target.commit_day(day_plan, day_error)) return false;
            } while (!day_plan.completed_day);
            return true;
        };
        // Free branch: grant on day 12, then open alongside the paid branch on
        // day 13 so both draws see the same committed-day RNG.
        // Copy constructed from a configured authority. The branch-local
        // helpers below use only command/plan/day paths, never implementation
        // private fields.
        RuntimeIdeologyPodAuthority free_authority = authority;
        RuntimeIdeologyPodAuthority paid_authority = authority;
        std::string branch_error;
        if (!close_offer(free_authority, branch_error) ||
                !close_offer(paid_authority, branch_error)) {
            error = "ideology_self_test_x6b_setup_failed"; return false;
        }
        const uint64_t free_rng = free_authority.snapshot().countries[0].rng_state;
        const uint64_t paid_rng = paid_authority.snapshot().countries[0].rng_state;
        const uint64_t free_draw_sequence =
            free_authority.snapshot().countries[0].draw_sequence;
        const uint64_t paid_draw_sequence =
            paid_authority.snapshot().countries[0].draw_sequence;
        const int64_t free_points =
            free_authority.snapshot().countries[0].ideology_points_q16;
        const int64_t paid_points =
            paid_authority.snapshot().countries[0].ideology_points_q16;
        RuntimeIdeologyPodPlan free_plan;
        // Grant first on its own day, then open on day 13.
        if (!run_command(free_authority,
                         RuntimeIdeologyPodOpcode::GRANT_FREE_DRAW, 101, 12,
                         1, free_plan, branch_error)) {
            error = "ideology_self_test_x6b_free_grant_failed"; return false;
        }
        free_plan = RuntimeIdeologyPodPlan{};
        const uint64_t granted_free_draws =
            free_authority.snapshot().countries[0].free_draws;
        if (granted_free_draws != 1) {
            error = "ideology_self_test_x6b_free_grant_not_visible_failed";
            return false;
        }
        if (!run_command(free_authority, RuntimeIdeologyPodOpcode::OPEN_OFFER,
                         102, 13, 0, free_plan, branch_error)) {
            error = "ideology_self_test_x6b_free_open_failed"; return false;
        }
        RuntimeIdeologyPodPlan paid_plan;
        if (!run_command(paid_authority, RuntimeIdeologyPodOpcode::OPEN_OFFER,
                         103, 13, 0, paid_plan, branch_error)) {
            error = "ideology_self_test_x6b_paid_open_failed"; return false;
        }
        const auto &free_row = free_authority.snapshot().countries[0];
        const auto &paid_row = paid_authority.snapshot().countries[0];
        if (free_rng != paid_rng ||
                free_draw_sequence != paid_draw_sequence ||
                free_points != paid_points ||
                free_row.free_draws != 0 ||
                paid_row.free_draws != 0 ||
                free_row.ideology_points_q16 != free_points ||
                paid_row.ideology_points_q16 >= paid_points ||
                free_row.draw_sequence != free_draw_sequence + 1u ||
                paid_row.draw_sequence != paid_draw_sequence + 1u ||
                free_row.rng_state != paid_row.rng_state ||
                free_row.offer.generation != paid_row.offer.generation ||
                free_row.offer.choice_count != paid_row.offer.choice_count) {
            error = "ideology_self_test_x6b_rng_or_accounting_failed"; return false;
        }
        for (int32_t choice = 0; choice < free_row.offer.choice_count; ++choice) {
            if (free_row.offer.ideology_ids[static_cast<size_t>(choice)] !=
                    paid_row.offer.ideology_ids[static_cast<size_t>(choice)]) {
                error = "ideology_self_test_x6b_offer_mismatch_failed"; return false;
            }
        }
    }
    // Same reroll, but with the frozen reroll factor at 2x: the charge has to
    // double. This is the only place the factor is observed end to end — the
    // kernel facts above only prove the arithmetic, not that apply_command
    // reads the array at all.
    {
        RuntimeIdeologyOpinionSnapshot costly = grow;
        costly.reroll_cost_q16 = {static_cast<int32_t>(2 * Q16_ONE)};
        const int64_t before_costly =
            authority.snapshot().countries[0].ideology_points_q16;
        auto reroll_costly = command(12, RuntimeIdeologyPodOpcode::REROLL_OFFER, -1, 0, 0);
        reroll_costly.effective_day = reroll_costly.requested_day = 12;
        reroll_costly.offer_generation =
            authority.snapshot().countries[0].offer.generation;
        if (!authority.queue_command(reroll_costly, error)) return false;
        do { if (!authority.plan_day(12, country, costly, {}, plan, error) ||
                   !authority.commit_day(plan, error)) return false; } while (!plan.completed_day);
        if (authority.snapshot().countries[0].offer.active == 0 ||
            before_costly - authority.snapshot().countries[0].ideology_points_q16
                != Q16_ONE) {
            error = "ideology_self_test_reroll_factor_failed"; return false;
        }
    }
    // A1 / 6b: settlement-count invariance.
    //
    // The property that makes parity possible: over the same 30 days, settling
    // once, thirty times, or a random number of times must pay the SAME trade
    // total. Previously trade paid `trade_per_day` on every settlement and then
    // suppressed a second settlement in the same day, which made the total a
    // function of the settlement count -- 46859 vs 67969 in the field.
    {
        constexpr int64_t kDays = 30;
        constexpr int64_t kTradePerDay = 1000;     // already weight-scaled
        constexpr int64_t kPeriod = 5;             // opinion period, < kDays
        // EVERY schedule starts with day 1, because the first observation SEEDS
        // the marker and pays nothing. A schedule that begins at day 30 would
        // seed there and pay zero, which is correct behaviour but not the same
        // experiment: what is under test is "the same elapsed span, settled a
        // different number of times", so all schedules share the seed day.
        auto settle_total = [&](const std::vector<int64_t> &later_settlements) {
            int64_t paid = INT64_MIN;
            int64_t total = ideology_trade_flow_q16(kTradePerDay, 1, kPeriod, paid);
            for (int64_t day : later_settlements)
                total += ideology_trade_flow_q16(kTradePerDay, day, kPeriod, paid);
            return total;
        };
        // 1) once, at the end
        // 2) every day
        // 3) every `kPeriod` days (the production case: period-aligned commits)
        // 4) an irregular deterministic subset, including same-day repeats
        std::vector<int64_t> once = {kDays};
        std::vector<int64_t> daily;
        std::vector<int64_t> periodic;
        std::vector<int64_t> ragged;
        for (int64_t day = 2; day <= kDays; ++day) {
            daily.push_back(day);
            if (day % kPeriod == 0) periodic.push_back(day);
            // Deterministic pattern with irregular gaps, including repeats.
            if ((day * 7 + 3) % 5 != 0) ragged.push_back(day);
            if (day % 11 == 0) ragged.push_back(day);
        }
        const int64_t once_total = settle_total(once);
        const int64_t daily_total = settle_total(daily);
        const int64_t periodic_total = settle_total(periodic);
        const int64_t ragged_total = settle_total(ragged);
        if (once_total != daily_total || once_total != periodic_total ||
            once_total != ragged_total) {
            error = "ideology_self_test_trade_settlement_invariance_failed";
            return false;
        }
        // And the amount itself must be right, not merely equal: day 1 seeds, so
        // 29 elapsed days at 1000/day is 29000.
        const int64_t expected = kTradePerDay * (kDays - 1);
        if (once_total != expected) {
            error = "ideology_self_test_trade_settlement_amount_failed";
            return false;
        }
        // A gap longer than the period pays the WHOLE gap, not one period. This
        // is the assertion that pins the decision not to clamp: the clamp read
        // "total depends only on elapsed days" while paying `period` for a
        // 99-day gap, which made a single settlement pay less than daily ones.
        int64_t wide_paid = INT64_MIN;
        if (ideology_trade_flow_q16(kTradePerDay, 1, kPeriod, wide_paid) != 0 ||
            ideology_trade_flow_q16(kTradePerDay, 100, kPeriod, wide_paid)
                != kTradePerDay * 99) {
            error = "ideology_self_test_trade_settlement_gap_failed";
            return false;
        }
        // Repeats in the same day pay once.
        int64_t repeat_paid = INT64_MIN;
        if (ideology_trade_flow_q16(kTradePerDay, 1, kPeriod, repeat_paid) != 0 ||
            ideology_trade_flow_q16(kTradePerDay, 1, kPeriod, repeat_paid) != 0 ||
            ideology_trade_flow_q16(kTradePerDay, 2, kPeriod, repeat_paid)
                != kTradePerDay) {
            error = "ideology_self_test_trade_settlement_repeat_failed";
            return false;
        }
    }
    std::vector<uint8_t> bytes; authority.serialize(bytes);
    RuntimeIdeologyPodAuthority restored;
    if (!restored.configure(catalog, error) || !restored.restore(bytes.data(), bytes.size(), error) ||
        restored.snapshot().state_hash != authority.snapshot().state_hash) { error = "ideology_self_test_save_roundtrip_failed"; return false; }
    const uint64_t before = restored.snapshot().state_hash; bytes.back() ^= 0x40u;
    if (restored.restore(bytes.data(), bytes.size(), error) || restored.snapshot().state_hash != before) { error = "ideology_self_test_transactional_restore_failed"; return false; }
    error.clear();
    // R8-1: an OLDER payload must be refused by VERSION, and refused before the
    // body is decoded.
    //
    // The defect this pins: `trade_paid_day` (and then the accrual markers) were
    // appended to the country row while the ABI stayed 5, so a v5 file was
    // decoded with the v6 field layout and came out as a late, wrong error
    // (truncation or state-hash mismatch). Rebuild the header with the previous
    // ABI and a matching checksum, keeping every other byte: the catalog hash
    // and state hash are the ones this authority just wrote, so a reader that
    // skipped the version gate WOULD accept the payload. Only the version can
    // reject it, which is exactly the property being asserted.
    {
        constexpr uint32_t stale_abi = RUNTIME_IDEOLOGY_POD_ABI_VERSION - 1u;
        std::vector<uint8_t> stale;
        stale.reserve(bytes.size());
        append_le<uint32_t>(stale, SAVE_MAGIC);
        append_le<uint32_t>(stale, stale_abi);
        // Everything from the catalog hash to the last body byte, verbatim.
        constexpr size_t header_size = sizeof(uint32_t) * 2u;
        if (bytes.size() <= header_size + sizeof(uint64_t) ||
            stale.size() != header_size) {
            error = "ideology_self_test_stale_abi_setup_failed"; return false;
        }
        stale.insert(stale.end(), bytes.begin() + header_size,
                     bytes.end() - sizeof(uint64_t));
        append_le<uint64_t>(stale, hash_bytes(FNV_OFFSET, stale.data(), stale.size()));
        RuntimeIdeologyPodAuthority guard;
        if (!guard.configure(catalog, error)) {
            error = "ideology_self_test_stale_abi_setup_failed"; return false;
        }
        std::string stale_error;
        if (guard.restore(stale.data(), stale.size(), stale_error) ||
            stale_error != "ideology_pod_save_header_invalid") {
            error = "ideology_self_test_stale_abi_rejection_failed"; return false;
        }
        // And the current ABI still round-trips, so the gate rejects the old
        // version rather than everything.
        std::vector<uint8_t> fresh;
        authority.serialize(fresh);
        RuntimeIdeologyPodAuthority control;
        if (!control.configure(catalog, error) ||
            !control.restore(fresh.data(), fresh.size(), error) ||
            control.snapshot().state_hash != authority.snapshot().state_hash) {
            error = "ideology_self_test_stale_abi_control_failed"; return false;
        }
    }
    error.clear(); return true;
}

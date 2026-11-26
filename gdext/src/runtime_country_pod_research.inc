bool RuntimeCountryPodAuthority::run_research_day(
        RuntimeCountryPodSnapshot &state, int64_t day,
        RuntimeCountryPodPlan &plan, std::string &error) const {
    error.clear();
    if (_catalog.technology_points_good_id < 0 ||
        _catalog.technology_points_good_id >= static_cast<int32_t>(state.good_count)) {
        error = "country_research_points_good_missing";
        return false;
    }
    if (state.last_research_day > day) {
        error = "country_research_day_regressed";
        return false;
    }
    const bool research_due = day > state.last_research_day;
    const auto make_handle = [&state](int32_t slot) {
        return (static_cast<uint64_t>(state.country_generation[
            static_cast<size_t>(slot)]) << 32u) |
            static_cast<uint32_t>(slot);
    };
    const auto pending_bit = [&state](int32_t slot, int32_t technology) {
        const size_t word = static_cast<size_t>(slot) * state.technology_words +
            static_cast<size_t>(technology / 64);
        return std::pair<size_t, uint64_t>{word, uint64_t{1} << (technology % 64)};
    };
    const auto add_effect_intent = [&](int32_t slot, int32_t technology) {
        for (const RuntimeDomainIntent &existing : plan.intents) {
            if (existing.target_handle == make_handle(slot) &&
                existing.payload[0] == technology &&
                existing.opcode == static_cast<uint16_t>(
                    CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT))
                return;
        }
        RuntimeDomainIntent intent;
        intent.source_domain = static_cast<uint16_t>(RuntimeDomainId::COUNTRY);
        intent.target_domain = static_cast<uint16_t>(RuntimeDomainId::EFFECT);
        intent.opcode = static_cast<uint16_t>(
            CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT);
        intent.flags = RUNTIME_DOMAIN_INTENT_REQUIRES_ACK;
        intent.target_handle = make_handle(slot);
        intent.target_generation = state.country_generation[static_cast<size_t>(slot)];
        intent.effective_day = day;
        intent.payload[0] = technology;
        intent.request_id = country_peer_request_id(
            state.session_epoch == 0 ? 1u : state.session_epoch,
            state.generation, day, 0u, slot, technology,
            CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT);
        intent.source_id = intent.request_id;
        intent.idempotency_key = intent.request_id;
        intent.producer_id = 0;
        intent.sequence = intent.request_id;
        plan.intents.push_back(intent);
    };

    // Completion is a state transition, not a technology-points purchase.
    // A queue head can already cover its cost — a starter-eligible technology
    // compiles to cost 0, and an ordinary one can have spent its last unit on
    // an earlier day. country_advance_research_progress reports such a head as
    // completed with spend == 0, and the allocation loop below breaks on
    // spend <= 0 before it ever looks at `completed`. Without this pass the
    // head parks in the queue forever at 「还需 0」 and never enters pending.
    // Mirrors NativeCountryRuntime::finalize_research_head_if_complete.
    const auto finalize_complete_head = [&](int32_t slot, uint32_t domain) {
        const size_t lane = static_cast<size_t>(slot) *
            RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT + domain;
        uint8_t &length = state.research_queue_lengths[lane];
        if (length == 0) return false;
        const size_t queue_base = lane * COUNTRY_QUEUE_SLOTS;
        const int32_t technology = state.research_queues[queue_base];
        if (technology < 0 ||
            technology >= static_cast<int32_t>(state.technology_count))
            return false;
        const auto [word, bit] = pending_bit(slot, technology);
        if ((state.country_technologies[word] & bit) != 0 ||
            (state.country_pending_technologies[word] & bit) != 0)
            return false;
        if (!technology_prerequisites_met(state, slot, technology)) return false;
        const int64_t effective_cost = country_effective_research_cost(
            _catalog.technology_costs[static_cast<size_t>(technology)],
            state.research_cost_factor[static_cast<size_t>(slot)]);
        const int64_t progress = state.research_progress[
            static_cast<size_t>(slot) * state.technology_count +
            static_cast<size_t>(technology)];
        if (progress < effective_cost) return false;

        state.country_pending_technologies[word] |= bit;
        ++state.research_completed_total[static_cast<size_t>(slot)];
        ++state.country_state_version[static_cast<size_t>(slot)];
        for (int32_t index = 1; index < length; ++index)
            state.research_queues[queue_base + static_cast<size_t>(index - 1)] =
                state.research_queues[queue_base + static_cast<size_t>(index)];
        state.research_queues[queue_base + static_cast<size_t>(--length)] = -1;
        if (_catalog.technology_effect_required[
                static_cast<size_t>(technology)] != 0)
            add_effect_intent(slot, technology);
        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        return true;
    };

    const auto visit_slot = [&](int32_t slot) -> bool {
        if (slot < 0 || slot >= static_cast<int32_t>(state.country_count) ||
            state.country_active[static_cast<size_t>(slot)] == 0)
            return true;
        const size_t country_base = static_cast<size_t>(slot) *
            RUNTIME_COUNTRY_RESEARCH_DOMAIN_COUNT;
        // Activation is always checked, including same-day continuation.
        for (uint32_t technology = 0; technology < state.technology_count; ++technology) {
            const auto [word, bit] = pending_bit(slot, static_cast<int32_t>(technology));
            if ((state.country_pending_technologies[word] & bit) == 0) continue;
            const uint8_t flags = state.research_peer_flags[
                static_cast<size_t>(slot) * state.technology_count + technology];
            const bool requires_peer = _catalog.technology_effect_required[technology] != 0;
            const bool peer_ready = !requires_peer ||
                (flags & (COUNTRY_PEER_EFFECT_FIRE_ACKED |
                          COUNTRY_PEER_MODIFIER_APPLIED)) != 0;
            if (peer_ready) {
                if (!activate_pending_technology(
                        state, slot, static_cast<int32_t>(technology), plan,
                        flags, error))
                    return false;
                if ((state.country_pending_technologies[word] & bit) == 0)
                    plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
            } else {
                add_effect_intent(slot, static_cast<int32_t>(technology));
            }
        }
        // Runs before the points gate: a zero-cost head must finalize even on
        // a day with an empty treasury or no research due.
        for (uint32_t domain = 0; domain < COUNTRY_RESEARCH_DOMAIN_COUNT; ++domain)
            while (finalize_complete_head(slot, domain)) {}
        // Drop owned / pending heads even when no TP will be spent today so
        // a settled tech cannot keep blocking later queue entries across days.
        for (uint32_t domain = 0; domain < COUNTRY_RESEARCH_DOMAIN_COUNT; ++domain) {
            const size_t lane = country_base + domain;
            while (true) {
                uint8_t &length = state.research_queue_lengths[lane];
                if (length == 0) break;
                const size_t queue_base = lane * COUNTRY_QUEUE_SLOTS;
                const int32_t technology = state.research_queues[queue_base];
                if (technology < 0 ||
                    technology >= static_cast<int32_t>(state.technology_count))
                    break;
                const auto [word, bit] = pending_bit(slot, technology);
                if ((state.country_technologies[word] & bit) == 0 &&
                    (state.country_pending_technologies[word] & bit) == 0)
                    break;
                for (int32_t index = 1; index < length; ++index)
                    state.research_queues[queue_base +
                        static_cast<size_t>(index - 1)] =
                        state.research_queues[queue_base +
                            static_cast<size_t>(index)];
                state.research_queues[queue_base +
                    static_cast<size_t>(--length)] = -1;
                plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
            }
        }
        if (!research_due) return true;

        int64_t &stock = state.country_goods[static_cast<size_t>(slot) *
            state.good_count + static_cast<size_t>(_catalog.technology_points_good_id)];
        const int64_t prior_deferred = std::min(
            state.research_deferred_points[static_cast<size_t>(slot)], stock);
        const int64_t available = stock - prior_deferred;
        if (available <= 0) return true;
        std::array<int32_t, COUNTRY_RESEARCH_DOMAIN_COUNT> weights{{0, 0, 0, 0}};
        for (uint32_t domain = 0; domain < COUNTRY_RESEARCH_DOMAIN_COUNT; ++domain)
            weights[domain] = state.research_weights_bp[country_base + domain];
        uint64_t remainder_iterations = 0;
        CountryResearchAllocation allocation = country_allocate_research_points(
            available, weights, &remainder_iterations);
        std::array<int32_t, COUNTRY_RESEARCH_DOMAIN_COUNT> queue_lengths{{0, 0, 0, 0}};
        for (uint32_t domain = 0; domain < COUNTRY_RESEARCH_DOMAIN_COUNT; ++domain)
            queue_lengths[domain] = state.research_queue_lengths[country_base + domain];
        country_redirect_idle_research_shares(allocation, weights, queue_lengths);
        plan.header.work_units += remainder_iterations;
        int64_t consumed = 0;
        int64_t newly_deferred = 0;
        for (uint32_t domain = 0; domain < COUNTRY_RESEARCH_DOMAIN_COUNT; ++domain) {
            int64_t domain_points = allocation.shares[domain];
            const size_t lane = country_base + domain;
            const uint8_t initial_length = state.research_queue_lengths[lane];
            while (domain_points > 0) {
                uint8_t &length = state.research_queue_lengths[lane];
                if (length == 0) break;
                const size_t queue_base = lane * COUNTRY_QUEUE_SLOTS;
                const int32_t technology = state.research_queues[queue_base];
                if (technology < 0 || technology >= static_cast<int32_t>(state.technology_count)) {
                    error = "country_research_queue_technology_invalid";
                    return false;
                }
                // Mirror NativeCountryRuntime: owned / pending heads are inert.
                // Without this pop, advance sees remaining==0 → spend==0 and
                // breaks, parking every later queued tech at 0% forever while
                // the settled head still occupies the UI queue.
                {
                    const auto [owned_word, owned_bit] =
                        pending_bit(slot, technology);
                    if ((state.country_technologies[owned_word] & owned_bit) != 0 ||
                        (state.country_pending_technologies[owned_word] &
                         owned_bit) != 0) {
                        for (int32_t index = 1; index < length; ++index)
                            state.research_queues[queue_base +
                                static_cast<size_t>(index - 1)] =
                                state.research_queues[queue_base +
                                    static_cast<size_t>(index)];
                        state.research_queues[queue_base +
                            static_cast<size_t>(--length)] = -1;
                        plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
                        continue;
                    }
                }
                if (!technology_prerequisites_met(state, slot, technology)) break;
                const int64_t progress = state.research_progress[
                    static_cast<size_t>(slot) * state.technology_count +
                    static_cast<size_t>(technology)];
                const double cost_factor = state.research_cost_factor[static_cast<size_t>(slot)];
                const double efficiency = state.research_efficiency[
                    static_cast<size_t>(slot) * 4u + domain];
                const CountryResearchProgress step = country_advance_research_progress(
                    progress, _catalog.technology_costs[static_cast<size_t>(technology)],
                    cost_factor, efficiency, domain_points);
                if (!step.valid || step.spend <= 0) break;
                state.research_progress[static_cast<size_t>(slot) * state.technology_count +
                                        static_cast<size_t>(technology)] =
                    progress + step.progress_gain;
                domain_points -= step.spend;
                consumed += step.spend;
                state.research_progress_total[static_cast<size_t>(slot)] +=
                    step.progress_gain;
                plan.header.work_units += static_cast<uint64_t>(step.spend);
                if (!step.completed) break;

                const auto [word, bit] = pending_bit(slot, technology);
                state.country_pending_technologies[word] |= bit;
                ++state.research_completed_total[static_cast<size_t>(slot)];
                ++state.country_state_version[static_cast<size_t>(slot)];
                for (int32_t index = 1; index < length; ++index)
                    state.research_queues[queue_base + static_cast<size_t>(index - 1)] =
                        state.research_queues[queue_base + static_cast<size_t>(index)];
                state.research_queues[queue_base + static_cast<size_t>(--length)] = -1;
                if (_catalog.technology_effect_required[static_cast<size_t>(technology)] != 0)
                    add_effect_intent(slot, technology);
            }
            if (initial_length > 0) newly_deferred += domain_points;
        }
        // A head whose last unit was spent above reports completed only on the
        // next advance, which would break on spend == 0. Settle it here so the
        // queue never stalls on an already-paid technology.
        for (uint32_t domain = 0; domain < COUNTRY_RESEARCH_DOMAIN_COUNT; ++domain)
            while (finalize_complete_head(slot, domain)) {}
        if (consumed > 0) {
            stock -= consumed;
            state.research_consumed_total[static_cast<size_t>(slot)] += consumed;
            ++state.country_state_version[static_cast<size_t>(slot)];
            plan.header.dirty_families |= RUNTIME_DIRTY_COUNTRY_STATE;
        }
        state.research_deferred_points[static_cast<size_t>(slot)] = std::min(
            stock, prior_deferred + newly_deferred);
        return true;
    };

    bool research_ok = true;
    if (state.research_active_index_valid && !state.research_active_country_slots.empty()) {
        for (const int32_t slot : state.research_active_country_slots) {
            if (!visit_slot(slot)) {
                research_ok = false;
                break;
            }
        }
    } else {
        for (uint32_t slot = 0; slot < state.country_count; ++slot) {
            if (!visit_slot(static_cast<int32_t>(slot))) {
                research_ok = false;
                break;
            }
        }
    }
    if (!research_ok) return false;
    if (research_due) state.last_research_day = day;
    plan.header.dirty_families |= plan.intents.empty() ? 0u : RUNTIME_DIRTY_COUNTRY_STATE;
    return error.empty();
}

bool RuntimeCountryPodAuthority::activate_pending_technology(
        RuntimeCountryPodSnapshot &state, int32_t slot, int32_t technology,
        RuntimeCountryPodPlan &plan, uint8_t peer_flags,
        std::string &error) const {
    error.clear();
    if (slot < 0 || technology < 0 ||
        slot >= static_cast<int32_t>(state.country_count) ||
        technology >= static_cast<int32_t>(state.technology_count)) {
        error = "country_pending_activation_target_invalid";
        return false;
    }
    const size_t word = static_cast<size_t>(slot) * state.technology_words +
        static_cast<size_t>(technology / 64);
    const uint64_t bit = uint64_t{1} << (technology % 64);
    if ((state.country_pending_technologies[word] & bit) == 0) return true;

    const size_t peer_index = static_cast<size_t>(slot) * state.technology_count +
        static_cast<size_t>(technology);
    if (peer_index >= state.research_peer_flags.size()) {
        error = "country_pending_activation_peer_state_missing";
        return false;
    }
    state.research_peer_flags[peer_index] |= peer_flags;
    const bool requires_peer = _catalog.technology_effect_required[
        static_cast<size_t>(technology)] != 0;
    if (requires_peer &&
        (state.research_peer_flags[peer_index] &
            (COUNTRY_PEER_EFFECT_FIRE_ACKED | COUNTRY_PEER_MODIFIER_APPLIED)) == 0) {
        error = "country_pending_activation_peer_ack_missing";
        return false;
    }

    state.country_pending_technologies[word] &= ~bit;
    state.country_technologies[word] |= bit;
    ++state.country_state_version[static_cast<size_t>(slot)];
    if (static_cast<size_t>(technology) < _catalog.technology_flags.size() &&
        (_catalog.technology_flags[static_cast<size_t>(technology)] & 2) != 0)
        plan.activated_milestones.push_back({slot, technology});

    country_core_refresh_discovery(state, _catalog, slot);
    return true;
}

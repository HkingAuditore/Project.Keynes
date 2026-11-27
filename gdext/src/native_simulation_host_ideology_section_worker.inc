static std::shared_ptr<const RuntimeIdeologyOpinionSnapshot>
expand_ideology_opinion(const RuntimeCountryPodSnapshot &country,
        const RuntimeIdeologyOpinionSnapshot &opinion) {
    const size_t old_count = opinion.country_count, new_count = country.country_count;
    const size_t old_lanes = old_count * opinion.class_count;
    const size_t new_lanes = new_count * opinion.class_count;
    if (old_count >= new_count || country.country_generation.size() != new_count ||
        country.country_active.size() != new_count ||
        opinion.country_handles.size() != old_count || opinion.country_generations.size() != old_count ||
        opinion.population.size() != old_lanes || opinion.funds.size() != old_lanes ||
        opinion.owner_employed.size() != old_lanes || opinion.satisfaction_weighted.size() != old_lanes ||
        opinion.satisfaction_q16.size() != old_lanes) return {};
    auto out = std::make_shared<RuntimeIdeologyOpinionSnapshot>(opinion);
    for (size_t slot = old_count; slot < new_count; ++slot) {
        const uint64_t generation = country.country_generation[slot];
        out->country_generations.push_back(generation);
        out->country_handles.push_back(country.country_active[slot] ? (generation << 32) | slot : 0);
    }
    out->country_count = new_count;
    out->population.resize(new_lanes, 0);
    out->funds.resize(new_lanes, 0);
    out->owner_employed.resize(new_lanes, 0);
    out->satisfaction_weighted.resize(new_lanes, 0);
    out->satisfaction_q16.resize(new_lanes, 0);
    if (!out->incidence_measured.empty()) out->incidence_measured.resize(new_count, 0);
    if (!out->class_incidence_q16.empty())
        out->class_incidence_q16.resize(new_lanes * out->incidence_channel_count, 0);
    for (auto *values : {&out->country_population, &out->country_buildings_installed,
                         &out->country_trade_base_value}) {
        if (values->size() == old_count) values->resize(new_count, 0);
    }
    return out;
}

NativeSimulationHost::IdeologyStageOutcome
NativeSimulationHost::execute_ideology_worker_stage(
        int64_t day, RuntimeDayCommit &commit, std::string &error) {
    using Outcome = IdeologyStageOutcome;
    (void)commit;
    error.clear();
    if (!_ideology_pod_configured) {
        error = "ideology_pod_not_configured";
        return Outcome::FAULT;
    }
    // Every stage runs again when another domain parks the day, and the POD
    // committed it on the first attempt. Earlier days are a regression; a
    // restore that put the POD ahead of the calendar is plan_day's own case.
    const RuntimeIdeologyPodSnapshot &current = _ideology_pod_authority.snapshot();
    if (current.round_day < 0 && day <= current.committed_day &&
        !_ideology_pod_authority.import_supersedes_calendar()) {
        if (day == current.committed_day) return Outcome::ALREADY_COMMITTED;
        error = "ideology_day_not_monotonic";
        return Outcome::FAULT;
    }
    const auto country = std::atomic_load_explicit(
        &_country_snapshot, std::memory_order_acquire);
    if (country == nullptr) {
        error = "ideology_country_snapshot_missing";
        return Outcome::FAULT;
    }
    const auto opinion_view = copy_economy_opinion_view(day);
    assert(!opinion_view.data || opinion_view.observe(_opinion_view_version));
    auto opinion = opinion_view.data;
    if (opinion == nullptr) {
        prepare_player_ideology_responses(day, true);
        error = "ideology_opinion_snapshot_missing";
        return Outcome::AWAITING_OPINION;
    }
    if (const auto expanded = expand_ideology_opinion(*country, *opinion))
        opinion = expanded;
    // Freeze the country.ideology.* multipliers from the last committed Modifier
    // snapshot (Modifier runs after Ideology, so this is the previous day's
    // value). Only the opinion copy changes; the published input stays.
    //
    // One loop per stat rather than one pass bucketing all three: buckets are
    // sorted by (domain, scope, stat), so a single pass could collect all three
    // in one sweep, but the sweep runs once per day per country and the three
    // passes keep the "which array does this bucket belong to" question inside
    // the lambda instead of in a switch nobody tests.
    if (_modifier_pod_configured &&
        opinion->country_population.size() == opinion->country_count &&
        (_ideology_pod_catalog.point_gain_stat_id >= 0 ||
         _ideology_pod_catalog.understanding_gain_stat_id >= 0 ||
         _ideology_pod_catalog.reroll_cost_stat_id >= 0 ||
         _ideology_pod_catalog.era_decay_floor_stat_id >= 0 ||
         _ideology_pod_catalog.offer_choice_bonus_stat_id >= 0 ||
         _ideology_pod_catalog.point_population_factor_stat_id >= 0 ||
         _ideology_pod_catalog.point_building_factor_stat_id >= 0 ||
         _ideology_pod_catalog.point_trade_factor_stat_id >= 0 ||
         _ideology_pod_catalog.opinion_factor_floor_stat_id >= 0 ||
         !_ideology_pod_catalog.school_strength_factor_stat_ids.empty())) {
        auto with_factors = std::make_shared<RuntimeIdeologyOpinionSnapshot>(*opinion);
        const RuntimeModifierCommittedView modifier_view =
            _modifier_pod_authority.copy_committed_view();
        assert(_modifier_pod_authority.observe_committed_view(modifier_view));
        const auto &buckets = modifier_view.buckets;
        auto freeze = [&](int32_t stat_id, std::vector<int32_t> &out,
                          double minimum = 0.0, double maximum = 4.0) {
            if (stat_id < 0) return;
            out.assign(opinion->country_count, 65536);
            for (const RuntimeModifierPodBucket &bucket : buckets) {
                if (bucket.domain != 1 || bucket.scope != 2 ||
                    bucket.stat_id != static_cast<uint32_t>(stat_id)) continue;
                const uint32_t slot =
                    static_cast<uint32_t>(bucket.scope_id & 0xffffffffull);
                if (slot >= opinion->country_count ||
                    opinion->country_handles[slot] != bucket.scope_id) continue;
                double value = (1.0 + bucket.sum_add) * bucket.product_factor;
                if (!std::isfinite(value)) value = 1.0;
                value = std::clamp(value, minimum, maximum);
                out[slot] = static_cast<int32_t>(std::lround(value * 65536.0));
            }
        };
        freeze(_ideology_pod_catalog.point_gain_stat_id,
               with_factors->point_gain_factor_q16);
        freeze(_ideology_pod_catalog.understanding_gain_stat_id,
               with_factors->understanding_gain_q16);
        freeze(_ideology_pod_catalog.reroll_cost_stat_id,
               with_factors->reroll_cost_q16);
        freeze(_ideology_pod_catalog.point_population_factor_stat_id,
               with_factors->point_population_factor_q16, 0.5, 3.0);
        freeze(_ideology_pod_catalog.point_building_factor_stat_id,
               with_factors->point_building_factor_q16, 0.5, 3.0);
        freeze(_ideology_pod_catalog.point_trade_factor_stat_id,
               with_factors->point_trade_factor_q16, 0.5, 3.0);
        // The opinion floor is ADDitive from a 0.5 base and clamped to
        // [0.3, 0.5]. A negative row therefore lowers the floor without ever
        // producing a negative multiplier.
        auto freeze_opinion_floor = [&]() {
            if (_ideology_pod_catalog.opinion_factor_floor_stat_id < 0) return;
            with_factors->opinion_factor_floor_q16.assign(
                opinion->country_count, 32768);
            for (const RuntimeModifierPodBucket &bucket : buckets) {
                if (bucket.domain != 1 || bucket.scope != 2 ||
                    bucket.stat_id != static_cast<uint32_t>(
                        _ideology_pod_catalog.opinion_factor_floor_stat_id))
                    continue;
                const uint32_t slot =
                    static_cast<uint32_t>(bucket.scope_id & 0xffffffffull);
                if (slot >= opinion->country_count ||
                    opinion->country_handles[slot] != bucket.scope_id)
                    continue;
                double value = (0.5 + bucket.sum_add) * bucket.product_factor;
                if (!std::isfinite(value)) value = 0.5;
                with_factors->opinion_factor_floor_q16[slot] =
                    static_cast<int32_t>(std::lround(
                        std::clamp(value, 0.3, 0.5) * 65536.0));
            }
        };
        freeze_opinion_floor();
        const int32_t school_count = static_cast<int32_t>(
            _ideology_pod_catalog.school_keys.size());
        if (school_count > 0 &&
            _ideology_pod_catalog.school_strength_factor_stat_ids.size() ==
                static_cast<size_t>(school_count)) {
            with_factors->school_strength_factor_q16.assign(
                static_cast<size_t>(opinion->country_count) *
                    static_cast<size_t>(school_count), 65536);
            for (int32_t school = 0; school < school_count; ++school) {
                const int32_t stat_id =
                    _ideology_pod_catalog.school_strength_factor_stat_ids[
                        static_cast<size_t>(school)];
                if (stat_id < 0) continue;
                for (const RuntimeModifierPodBucket &bucket : buckets) {
                    if (bucket.domain != 1 || bucket.scope != 2 ||
                        bucket.stat_id != static_cast<uint32_t>(stat_id)) {
                        continue;
                    }
                    const uint32_t country_slot =
                        static_cast<uint32_t>(
                            bucket.scope_id & 0xffffffffull);
                    if (country_slot >= opinion->country_count ||
                        opinion->country_handles[country_slot] !=
                            bucket.scope_id) {
                        continue;
                    }
                    double value =
                        (1.0 + bucket.sum_add) * bucket.product_factor;
                    if (!std::isfinite(value)) value = 1.0;
                    const size_t lane =
                        static_cast<size_t>(country_slot) *
                            static_cast<size_t>(school_count) +
                        static_cast<size_t>(school);
                    with_factors->school_strength_factor_q16[lane] =
                        static_cast<int32_t>(std::lround(
                            std::clamp(value, 0.5, 2.0) * 65536.0));
                }
            }
        }
        // The two draw-side values are ADDITIVE, not multipliers: an empty array
        // has to read as 0 (no floor, no extra rows), while `freeze` seeds 65536
        // because 1.0 is the identity for a factor. Sharing `freeze` here would
        // silently give every country a 65536 bp floor and 65536 extra rows.
        auto freeze_additive = [&](int32_t stat_id, std::vector<int32_t> &out,
                                   int32_t ceiling) {
            if (stat_id < 0) return;
            out.assign(opinion->country_count, 0);
            for (const RuntimeModifierPodBucket &bucket : buckets) {
                if (bucket.domain != 1 || bucket.scope != 2 ||
                    bucket.stat_id != static_cast<uint32_t>(stat_id)) continue;
                const uint32_t slot =
                    static_cast<uint32_t>(bucket.scope_id & 0xffffffffull);
                if (slot >= opinion->country_count ||
                    opinion->country_handles[slot] != bucket.scope_id) continue;
                double value = bucket.sum_add;
                if (!std::isfinite(value)) value = 0.0;
                out[slot] = static_cast<int32_t>(std::lround(
                    std::clamp(value, 0.0, static_cast<double>(ceiling))));
            }
        };
        freeze_additive(_ideology_pod_catalog.era_decay_floor_stat_id,
                        with_factors->era_decay_floor_bp, 10000);
        freeze_additive(_ideology_pod_catalog.offer_choice_bonus_stat_id,
                        with_factors->offer_choice_bonus,
                        IDEOLOGY_OFFER_CHOICE_CAPACITY - IDEOLOGY_OFFER_CHOICE_BASE);
        opinion = std::move(with_factors);
    }
    // R9-1: publish the exact opinion THIS worker day settles from, now that every
    // transformation (including the frozen Modifier factors above) has happened.
    //
    // Recording earlier would hand parity a snapshot that still lacked the frozen
    // `point_gain_factor_q16`, so the two sides would settle from inputs that
    // differ in a field the accounting reads. The shared_ptr is kept alive by the
    // ring, so the main thread can consume it after this stage returns.
    if (_ideology_pod_authority.snapshot().countries.empty()) {
        if (!_ideology_pod_authority.bootstrap(*country, *opinion, error))
            return Outcome::PARKED;
    }
    if (domain_is_worker_authoritative(RuntimeDomainId::IDEOLOGY))
        queue_annual_worker_reward(day);
    std::deque<RuntimeIdeologyPodCommand> commands;
    std::vector<RuntimeDomainAck> acks;
    {
        std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
        commands.swap(_ideology_commands);
        acks.assign(_ideology_acks.begin(), _ideology_acks.end());
        _ideology_acks.clear();
    }
    while (!commands.empty()) {
        const RuntimeIdeologyPodCommand command = commands.front();
        commands.pop_front();
        if (!_ideology_pod_authority.queue_command(command, error)) {
            std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
            _ideology_commands.push_front(command);
            while (!commands.empty()) {
                _ideology_commands.push_front(commands.back());
                commands.pop_back();
            }
            return Outcome::PARKED;
        }
    }

    const auto plan_started = std::chrono::steady_clock::now();
    double replay_ms = 0.0;
    uint32_t emitted = 0;
    RuntimeIdeologyPodPlan plan;
    bool first_slice = true;
    for (uint32_t slice = 0; slice < RUNTIME_IDEOLOGY_POD_MAX_COMMANDS; ++slice) {
        static const std::vector<RuntimeDomainAck> empty_acks;
        const auto &effective_acks = first_slice ? acks : empty_acks;
        first_slice = false;
        if (!_ideology_pod_authority.plan_day(
                day, *country, *opinion, effective_acks, plan, error)) {
            _ideology_pod_authority.discard_plan();
            return Outcome::PARKED;
        }
        if (ideology_modifier_bridge_active()) {
            // Worker owns MODIFIER: keep the transition in-worker until the
            // Modifier POD has really applied its rows.
            for (const RuntimeDomainIntent &intent : plan.intents) {
                IdeologyModifierInflight inflight;
                inflight.intent = intent;
                for (const auto &row : plan.modifier_rows)
                    if (row.transition_id == intent.source_id)
                        inflight.rows.push_back(row);
                auto existing = std::find_if(
                    _ideology_modifier_inflight.begin(),
                    _ideology_modifier_inflight.end(),
                    [&](const IdeologyModifierInflight &item) {
                        return item.intent.source_id == intent.source_id;
                    });
                if (existing != _ideology_modifier_inflight.end())
                    *existing = std::move(inflight);
                else
                    _ideology_modifier_inflight.push_back(std::move(inflight));
                ++emitted;
            }
            for (const auto &row : plan.modifier_rows)
                if (row.transition_id == 0)
                    _ideology_loose_modifier_rows.push_back(row);
        } else {
            std::lock_guard<std::mutex> lock(_ideology_transport_mutex);
            for (const RuntimeDomainIntent &intent : plan.intents) {
                if (_ideology_intents.size() >= RUNTIME_DOMAIN_INTENT_CAPACITY) {
                    _ideology_pod_authority.discard_plan();
                    error = "ideology_intent_capacity_exceeded";
                    return Outcome::PARKED;
                }
                _ideology_intents.push_back(intent);
                ++emitted;
            }
        }
        const auto replay_started = std::chrono::steady_clock::now();
        if (!_ideology_pod_authority.commit_day(plan, error)) return Outcome::PARKED;
        replay_ms += std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - replay_started).count();
        if (plan.completed_day != 0) break;
        if (slice + 1u == RUNTIME_IDEOLOGY_POD_MAX_COMMANDS) {
            error = "ideology_same_day_continuation_limit_exceeded";
            return Outcome::PARKED;
        }
    }
    const RuntimeIdeologyPodSnapshot &snapshot =
        _ideology_pod_authority.snapshot();
    record_ideology_worker_opinion_use(
        day, *opinion, opinion, snapshot.generation);
    if (domain_is_worker_authoritative(RuntimeDomainId::IDEOLOGY))
        settle_annual_worker_reward(snapshot);
    auto copy = std::make_shared<RuntimeIdeologyPodSnapshot>(snapshot);
    std::atomic_store_explicit(&_ideology_snapshot,
        std::shared_ptr<const RuntimeIdeologyPodSnapshot>(std::move(copy)),
        std::memory_order_release);
    // G8: publish the immutable snapshot for main-thread NativeIdeologyRuntime
    // write-back. The shared_ptr above stays for SHADOW diagnostics readers.
    uint32_t ideology_slot = 0;
    if (_ideology_snapshots.try_begin_write(ideology_slot)) {
        _ideology_snapshots.write_buffer(ideology_slot) = snapshot;
        _ideology_snapshots.publish(ideology_slot);
    }
    _ideology_pod_plan_ms.store(
        std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - plan_started).count(),
        std::memory_order_release);
    _ideology_pod_replay_ms.store(replay_ms, std::memory_order_release);
    _ideology_pod_state_hash.store(snapshot.state_hash, std::memory_order_release);
    record_ideology_parity_locked(snapshot);
    _ideology_pod_snapshot_generation.store(snapshot.generation,
                                            std::memory_order_release);
    // The day the worker last committed Ideology for. Callers need this to tell
    // "the worker never advanced" apart from "it is simply behind"; the previous
    // report had no such field and a probe read a misspelled one, so every run
    // printed a stale `worker_day=1`.
    _ideology_pod_committed_day.store(snapshot.committed_day,
                                      std::memory_order_release);
    _ideology_pod_pending_transition_count.store(
        static_cast<uint32_t>(snapshot.pending_transitions.size()),
        std::memory_order_release);
    _ideology_pod_intent_count.store(emitted, std::memory_order_release);
    return Outcome::COMMITTED;
}

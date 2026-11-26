#include "country_runtime_peer_includes.inc"

namespace pk {

using namespace godot;

bool NativeCountryRuntime::capture_peer_context(
        int64_t day, uint32_t continuation_index,
        CountryPeerContext &out, std::string &error) const {
    out = CountryPeerContext{};
    error.clear();
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) {
        error = "country_peer_context_runtime_unavailable";
        return false;
    }
    if (day < 0) {
        error = "country_peer_context_day_invalid";
        return false;
    }

    out.session_epoch = _session_epoch;
    out.country_generation = _generation;
    out.modifier_generation = _modifier_runtime != nullptr &&
            modifier_api::configured(*_modifier_runtime)
        ? modifier_api::domain_snapshot_version(*_modifier_runtime, ModifierApi::COUNTRY)
        : 0;
    out.effect_generation = _effect_runtime_enabled && _effect_runtime != nullptr
        ? _effect_runtime->committed_generation() : 0;
    out.economy_generation = _economy_runtime != nullptr
        ? economy_api::committed_generation(*_economy_runtime) : 0;
    out.day = day;
    out.continuation_index = continuation_index;
    out.effect_enabled = _effect_runtime_enabled && _effect_runtime != nullptr ? 1 : 0;
    out.modifier_enabled = _modifier_runtime != nullptr &&
        modifier_api::configured(*_modifier_runtime) ? 1 : 0;
    out.economy_enabled = _economy_runtime != nullptr ? 1 : 0;
    out.effect_should_run = out.effect_enabled != 0 &&
        _effect_runtime->should_run(day) ? 1 : 0;
    out.modifier_should_run = out.modifier_enabled != 0 &&
        modifier_api::should_run(*_modifier_runtime, day) ? 1 : 0;

    constexpr double kFallbackMaxCostFactor = 4.0;
    out.max_research_cost_factor = kFallbackMaxCostFactor;
    if (out.modifier_enabled != 0) {
        out.max_research_cost_factor = modifier_api::stat_clamp_max(*_modifier_runtime,
            "country.research.cost_factor", kFallbackMaxCostFactor);
        if (!(out.max_research_cost_factor > 0.0) ||
            !std::isfinite(out.max_research_cost_factor))
            out.max_research_cost_factor = kFallbackMaxCostFactor;
    }

    const size_t country_count = _countries.active.size();
    out.research_cost_factor.assign(country_count, 1.0);
    out.research_efficiency.assign(country_count * 4u, 1.0);
    static constexpr const char *EFFICIENCY_STATS[4] = {
        "country.research.agriculture_efficiency",
        "country.research.engineering_efficiency",
        "country.research.science_efficiency",
        "country.research.society_efficiency",
    };
    if (out.modifier_enabled != 0) {
        for (size_t slot = 0; slot < country_count; ++slot) {
            if (_countries.active[slot] == 0) continue;
            const uint64_t handle = make_handle(static_cast<int32_t>(slot));
            double cost_factor = modifier_api::effective_value(*_modifier_runtime,
                ModifierApi::COUNTRY, "country.research.cost_factor",
                handle, 0, 1.0);
            if (!(cost_factor > 0.0) || !std::isfinite(cost_factor))
                cost_factor = 1.0;
            out.research_cost_factor[slot] = cost_factor;
            for (int32_t domain = 0; domain < 4; ++domain) {
                double efficiency = modifier_api::effective_value(*_modifier_runtime,
                    ModifierApi::COUNTRY, EFFICIENCY_STATS[domain],
                    handle, 0, 1.0);
                if (!(efficiency > 0.0) || !std::isfinite(efficiency))
                    efficiency = 1.0;
                out.research_efficiency[slot * 4u +
                    static_cast<size_t>(domain)] = efficiency;
            }
        }
    }

    const size_t technology_count = _technology_ids.size();
    out.technology_states.reserve(country_count);
    for (size_t slot = 0; slot < country_count; ++slot) {
        if (_countries.active[slot] == 0) continue;
        const size_t word_base = slot * static_cast<size_t>(_technology_words);
        for (size_t technology = 0; technology < technology_count; ++technology) {
            const size_t word = word_base + technology / 64u;
            if (word >= _country_pending_technologies.size() ||
                (_country_pending_technologies[word] &
                    (uint64_t{1} << (technology % 64u))) == 0)
                continue;
            CountryPeerTechnologyState state;
            state.country_slot = static_cast<int32_t>(slot);
            state.technology = static_cast<int32_t>(technology);
            state.target_handle = make_handle(state.country_slot);
            state.effect_instance_id = static_cast<uint64_t>(
                ((state.target_handle & 0x00007fffffffffffULL) << 16U) |
                static_cast<uint64_t>(technology + 1u));
            state.effect_generation = static_cast<uint32_t>(
                state.target_handle >> 32U);
            if (out.effect_enabled != 0 &&
                state.effect_instance_id > 0 && state.effect_generation != 0) {
                // Authority-aware: see the note in export_pod_snapshot. A
                // pessimistic EXISTS makes the adapter re-issue ENSURE (idempotent
                // but wasteful); a pessimistic FIRE_ACKED would keep the peer at
                // PENDING forever, so it is the one that actually has to be right.
                bool effect_exists = false;
                effect_pod_instance_exists(_effect_runtime, _effect_forwarder,
                    static_cast<int64_t>(state.effect_instance_id),
                    state.effect_generation, effect_exists);
                if (effect_exists) state.flags |= COUNTRY_PEER_EFFECT_EXISTS;
                bool effect_acked = false;
                effect_pod_instance_fire_acked(_effect_runtime, _effect_forwarder,
                    static_cast<int64_t>(state.effect_instance_id),
                    state.effect_generation, effect_acked);
                if (effect_acked) state.flags |= COUNTRY_PEER_EFFECT_FIRE_ACKED;
            }
            if (out.modifier_enabled != 0 &&
                technology < _technology_modifier_definition_keys.size() &&
                !_technology_modifier_definition_keys[technology].empty() &&
                modifier_api::has_technology_effect(*_modifier_runtime,
                    state.target_handle,
                    _technology_modifier_definition_keys[technology],
                    state.technology))
                state.flags |= COUNTRY_PEER_MODIFIER_APPLIED;
            out.technology_states.push_back(state);
        }
    }
    return true;
}

CountryPeerTechnologyState *NativeCountryRuntime::find_peer_technology_state(
        CountryPeerContext &context, int32_t slot, int32_t technology) {
    const auto it = std::lower_bound(context.technology_states.begin(),
        context.technology_states.end(), std::pair<int32_t, int32_t>{slot, technology},
        [](const CountryPeerTechnologyState &entry,
           const std::pair<int32_t, int32_t> &value) {
            return entry.country_slot < value.first ||
                (entry.country_slot == value.first &&
                 entry.technology < value.second);
        });
    return it != context.technology_states.end() &&
            it->country_slot == slot && it->technology == technology
        ? &(*it) : nullptr;
}

const CountryPeerTechnologyState *NativeCountryRuntime::find_peer_technology_state(
        const CountryPeerContext &context, int32_t slot,
        int32_t technology) const {
    const auto it = std::lower_bound(context.technology_states.begin(),
        context.technology_states.end(), std::pair<int32_t, int32_t>{slot, technology},
        [](const CountryPeerTechnologyState &entry,
           const std::pair<int32_t, int32_t> &value) {
            return entry.country_slot < value.first ||
                (entry.country_slot == value.first &&
                 entry.technology < value.second);
        });
    return it != context.technology_states.end() &&
            it->country_slot == slot && it->technology == technology
        ? &(*it) : nullptr;
}

CountryPeerTechnologyState &NativeCountryRuntime::ensure_peer_technology_state(
        CountryPeerContext &context, int32_t slot, int32_t technology) {
    auto it = std::lower_bound(context.technology_states.begin(),
        context.technology_states.end(), std::pair<int32_t, int32_t>{slot, technology},
        [](const CountryPeerTechnologyState &entry,
           const std::pair<int32_t, int32_t> &value) {
            return entry.country_slot < value.first ||
                (entry.country_slot == value.first &&
                 entry.technology < value.second);
        });
    if (it == context.technology_states.end() || it->country_slot != slot ||
        it->technology != technology) {
        CountryPeerTechnologyState state;
        state.country_slot = slot;
        state.technology = technology;
        const uint64_t handle = make_handle(slot);
        state.target_handle = handle;
        state.effect_instance_id = static_cast<uint64_t>(
            ((handle & 0x00007fffffffffffULL) << 16U) |
            static_cast<uint64_t>(technology + 1));
        state.effect_generation = static_cast<uint32_t>(handle >> 32U);
        it = context.technology_states.insert(it, state);
    }
    return *it;
}

CountryPeerIntent NativeCountryRuntime::make_peer_intent(
        const CountryPeerContext &context, CountryPeerIntentCode opcode,
        int32_t slot, int32_t technology, int64_t day_index) const {
    CountryPeerIntent intent;
    intent.opcode = opcode;
    intent.session_epoch = context.session_epoch;
    intent.country_generation = context.country_generation;
    switch (opcode) {
    case CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT:
    case CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT:
    case CountryPeerIntentCode::NOTIFY_ERA_REWARD:
        intent.peer_generation = context.effect_generation;
        break;
    case CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER:
        intent.peer_generation = context.modifier_generation;
        break;
    case CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE:
        intent.peer_generation = context.economy_generation;
        break;
    }
    intent.day = day_index;
    intent.continuation_index = context.continuation_index;
    intent.country_slot = slot;
    intent.technology = technology;
    intent.target_handle = slot >= 0 ? make_handle(slot) : 0;
    if (slot >= 0 && technology >= 0) {
        intent.effect_instance_id = static_cast<uint64_t>(
            ((intent.target_handle & 0x00007fffffffffffULL) << 16U) |
            static_cast<uint64_t>(technology + 1));
        intent.effect_generation = static_cast<uint32_t>(
            intent.target_handle >> 32U);
    }
    intent.request_id = country_peer_request_id(
        intent.session_epoch, intent.country_generation, intent.day,
        intent.continuation_index, slot, technology, opcode);
    intent.idempotency_key = intent.request_id ^ 0x504545525f4944ull;

    // A research completion can advance Country's generation before the peer
    // responds. Reuse the original same-day intent identity in that case;
    // otherwise a continuation would enqueue a second Effect request for the
    // exact same pending technology.
    const auto same_logical_intent = [&](const CountryPeerIntent &existing) {
        return existing.session_epoch == intent.session_epoch &&
            existing.day == intent.day && existing.opcode == intent.opcode &&
            existing.country_slot == intent.country_slot &&
            existing.technology == intent.technology &&
            existing.target_handle == intent.target_handle;
    };
    const CountryPeerIntent *selected_pending = nullptr;
    for (const auto &entry : _peer_pending_intents) {
        if (!same_logical_intent(entry.second)) continue;
        if (selected_pending == nullptr ||
            entry.second.request_id < selected_pending->request_id)
            selected_pending = &entry.second;
    }
    if (selected_pending != nullptr) return *selected_pending;

    const CountryPeerResult *selected_cached = nullptr;
    for (const auto &entry : _peer_result_cache) {
        const CountryPeerResult &existing = entry.second;
        if (existing.code == CountryPeerResultCode::REJECTED)
            continue;
        if (existing.session_epoch != intent.session_epoch ||
            existing.day != intent.day || existing.opcode != intent.opcode ||
            existing.country_slot != intent.country_slot ||
            existing.technology != intent.technology ||
            existing.target_handle != intent.target_handle)
            continue;
        if (selected_cached == nullptr ||
            existing.request_id < selected_cached->request_id)
            selected_cached = &existing;
    }
    if (selected_cached != nullptr) {
        intent.request_id = selected_cached->request_id;
        intent.country_generation = selected_cached->country_generation;
        intent.peer_generation = selected_cached->peer_generation;
        intent.continuation_index = selected_cached->continuation_index;
        intent.idempotency_key = intent.request_id ^ 0x504545525f4944ull;
    }
    return intent;
}

void NativeCountryRuntime::set_peer_async_mode(bool enabled) {
    _peer_async_mode = enabled;
}

CountryPeerProtocolStatus NativeCountryRuntime::peer_protocol_status() const {
    CountryPeerProtocolStatus status;
    status.async_mode = _peer_async_mode ? 1 : 0;
    status.pending_intents = static_cast<uint32_t>(std::min<size_t>(
        _peer_pending_intents.size(), std::numeric_limits<uint32_t>::max()));
    status.queued_intents = static_cast<uint32_t>(std::min<size_t>(
        _peer_intent_queue.size(), std::numeric_limits<uint32_t>::max()));
    status.rejected_intents = static_cast<uint32_t>(std::min<size_t>(
        _peer_rejected_results.size(), std::numeric_limits<uint32_t>::max()));

    const CountryPeerResult *selected = nullptr;
    bool selected_unreported = false;
    for (const auto &entry : _peer_rejected_results) {
        const CountryPeerResult &candidate = entry.second;
        const bool unreported = _peer_rejection_reported.find(
            candidate.request_id) == _peer_rejection_reported.end();
        if (selected == nullptr ||
            (unreported && !selected_unreported) ||
            (unreported == selected_unreported &&
             candidate.request_id < selected->request_id)) {
            selected = &candidate;
            selected_unreported = unreported;
        }
        const int64_t candidate_retry_day = candidate.day <
                std::numeric_limits<int64_t>::max()
            ? candidate.day + 1 : candidate.day;
        if (status.retry_day < 0 || candidate_retry_day < status.retry_day)
            status.retry_day = candidate_retry_day;
        if (unreported)
            status.has_unreported_rejection = 1;
    }
    if (selected != nullptr) {
        status.rejected_request_id = selected->request_id;
        status.rejected_opcode = selected->opcode;
        status.rejection_reason = selected->reason;
    }
    return status;
}

void NativeCountryRuntime::remember_peer_rejection(
        const CountryPeerResult &result) {
    if (result.code != CountryPeerResultCode::REJECTED ||
        result.request_id == 0)
        return;
    _peer_rejected_results[result.request_id] = result;
    _peer_rejection_reported.erase(result.request_id);
}

void NativeCountryRuntime::clear_peer_rejections_for_retry(
        const CountryPeerIntent &intent) {
    const auto is_technology_intent = [](CountryPeerIntentCode opcode) {
        return opcode == CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT ||
            opcode == CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT ||
            opcode == CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER;
    };
    std::vector<uint64_t> obsolete;
    obsolete.reserve(_peer_rejected_results.size());
    for (const auto &entry : _peer_rejected_results) {
        const CountryPeerResult &rejection = entry.second;
        if (rejection.request_id == intent.request_id ||
            rejection.session_epoch != intent.session_epoch ||
            rejection.day >= intent.day ||
            rejection.country_slot != intent.country_slot ||
            rejection.technology != intent.technology ||
            rejection.target_handle != intent.target_handle)
            continue;
        const bool same_technology_retry =
            is_technology_intent(rejection.opcode) &&
            is_technology_intent(intent.opcode);
        if (!same_technology_retry && rejection.opcode != intent.opcode)
            continue;
        obsolete.push_back(entry.first);
    }
    for (const uint64_t request_id : obsolete) {
        _peer_rejected_results.erase(request_id);
        _peer_rejection_reported.erase(request_id);
        const auto cached = _peer_result_cache.find(request_id);
        if (cached != _peer_result_cache.end() &&
            cached->second.code == CountryPeerResultCode::REJECTED)
            _peer_result_cache.erase(cached);
    }
}

bool NativeCountryRuntime::peer_rejection_blocks_activation(
        int32_t slot, int32_t technology, int64_t day) const {
    for (const auto &entry : _peer_rejected_results) {
        const CountryPeerResult &rejection = entry.second;
        if (rejection.country_slot != slot ||
            rejection.technology != technology ||
            (rejection.opcode != CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT &&
             rejection.opcode != CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT &&
             rejection.opcode != CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER))
            continue;
        const int64_t retry_day = rejection.day <
                std::numeric_limits<int64_t>::max()
            ? rejection.day + 1 : rejection.day;
        // The first pass after an ACK must consume and report the rejection.
        // Once reported, the same logical activation is held until the next
        // calendar day, where a new request identity is created.
        if (_peer_rejection_reported.find(rejection.request_id) ==
                _peer_rejection_reported.end() && day >= rejection.day)
            return false;
        if (day < retry_day) return true;
    }
    return false;
}

bool NativeCountryRuntime::peer_rejection_needs_service(int64_t day) const {
    for (const auto &entry : _peer_rejected_results) {
        const CountryPeerResult &rejection = entry.second;
        if (_peer_rejection_reported.find(rejection.request_id) ==
                _peer_rejection_reported.end() && day >= rejection.day)
            return true;
        const int64_t retry_day = rejection.day <
                std::numeric_limits<int64_t>::max()
            ? rejection.day + 1 : rejection.day;
        if (day >= retry_day) return true;
    }
    return false;
}

void NativeCountryRuntime::mark_peer_rejections_reported(int64_t day) {
    for (const auto &entry : _peer_rejected_results) {
        if (entry.second.day <= day)
            _peer_rejection_reported.insert(entry.first);
    }
}

bool NativeCountryRuntime::retry_peer_rejections(
        int64_t day, CountryPeerContext &context) {
    std::vector<uint64_t> retry_ids;
    retry_ids.reserve(_peer_rejected_results.size());
    for (const auto &entry : _peer_rejected_results) {
        const CountryPeerResult &rejection = entry.second;
        const int64_t retry_day = rejection.day <
                std::numeric_limits<int64_t>::max()
            ? rejection.day + 1 : rejection.day;
        if (day < retry_day) continue;
        // Technology activation retries are driven by the pending bitset in
        // run_research_day. Only post-activation peer work is retried here;
        // otherwise the same intent would be emitted twice in one boundary.
        if (rejection.opcode == CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT ||
            rejection.opcode == CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT ||
            rejection.opcode == CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER)
            continue;
        retry_ids.push_back(entry.first);
    }
    std::sort(retry_ids.begin(), retry_ids.end());
    bool protocol_fault = false;
    for (const uint64_t request_id : retry_ids) {
        const auto found = _peer_rejected_results.find(request_id);
        if (found == _peer_rejected_results.end()) continue;
        const CountryPeerResult previous = found->second;
        const CountryPeerIntent retry = make_peer_intent(
            context, previous.opcode, previous.country_slot,
            previous.technology, day);
        if (retry.request_id == previous.request_id) {
            protocol_fault = true;
            continue;
        }
        // Applying a retry may insert a new rejection and rehash the map, so
        // remove the old entry before calling apply_peer_intent().
        _peer_rejected_results.erase(request_id);
        _peer_rejection_reported.erase(request_id);
        const CountryPeerResult result = apply_peer_intent(context, retry);
        if (result.code == CountryPeerResultCode::STALE)
            protocol_fault = true;
    }
    return !protocol_fault;
}

void NativeCountryRuntime::clear_peer_protocol_state() {
    _peer_pending_intents.clear();
    _peer_intent_queue.clear();
    _peer_result_cache.clear();
    _peer_rejected_results.clear();
    _peer_rejection_reported.clear();
    _peer_async_mode = false;
}

bool NativeCountryRuntime::poll_peer_intent(CountryPeerIntent &out) {
    while (!_peer_intent_queue.empty()) {
        const uint64_t request_id = _peer_intent_queue.front();
        _peer_intent_queue.pop_front();
        const auto found = _peer_pending_intents.find(request_id);
        if (found == _peer_pending_intents.end()) continue;
        out = found->second;
        return true;
    }
    return false;
}

bool NativeCountryRuntime::peer_result_identity_matches(
        const CountryPeerIntent &intent, const CountryPeerResult &result,
        std::string &error) const {
    error.clear();
    if (result.protocol_version != COUNTRY_PEER_PROTOCOL_VERSION) {
        error = "country_peer_result_protocol_invalid";
        return false;
    }
    if (result.request_id != intent.request_id ||
        result.session_epoch != intent.session_epoch ||
        result.country_generation != intent.country_generation ||
        result.peer_generation != intent.peer_generation ||
        result.day != intent.day ||
        result.continuation_index != intent.continuation_index ||
        result.opcode != intent.opcode ||
        result.country_slot != intent.country_slot ||
        result.technology != intent.technology ||
        result.target_handle != intent.target_handle) {
        error = "country_peer_result_identity_mismatch";
        return false;
    }
    return true;
}

void NativeCountryRuntime::apply_peer_result_to_context(
        CountryPeerContext &context, const CountryPeerResult &result) {
    if (result.committed_peer_generation != 0) {
        switch (result.opcode) {
        case CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT:
        case CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT:
        case CountryPeerIntentCode::NOTIFY_ERA_REWARD:
            context.effect_generation = result.committed_peer_generation;
            break;
        case CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER:
            context.modifier_generation = result.committed_peer_generation;
            break;
        case CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE:
            context.economy_generation = result.committed_peer_generation;
            break;
        }
    }
    if (!result.ok() || result.technology_flags == 0 ||
        result.country_slot < 0 || result.technology < 0 ||
        result.technology >= static_cast<int32_t>(_technology_ids.size()))
        return;
    CountryPeerTechnologyState &state = ensure_peer_technology_state(
        context, result.country_slot, result.technology);
    state.flags = result.technology_flags;
}

bool NativeCountryRuntime::submit_peer_result(
        const CountryPeerResult &result, std::string &error) {
    error.clear();
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) {
        error = "country_peer_result_runtime_unavailable";
        return false;
    }
    if (result.request_id == 0 ||
        static_cast<uint8_t>(result.code) >
            static_cast<uint8_t>(CountryPeerResultCode::STALE)) {
        error = "country_peer_result_invalid";
        return false;
    }
    if (result.code == CountryPeerResultCode::STALE) {
        // STALE describes a protocol identity failure. It is not a durable
        // business rejection and must never enter the retry queue.
        error = "country_peer_result_stale_terminal_invalid";
        return false;
    }
    const auto pending = _peer_pending_intents.find(result.request_id);
    const auto cached = _peer_result_cache.find(result.request_id);
    if (pending == _peer_pending_intents.end()) {
        if (cached == _peer_result_cache.end()) {
            error = "country_peer_result_request_unknown";
            return false;
        }
        const CountryPeerResult &previous = cached->second;
        if (previous.protocol_version != result.protocol_version ||
            previous.request_id != result.request_id ||
            previous.session_epoch != result.session_epoch ||
            previous.country_generation != result.country_generation ||
            previous.peer_generation != result.peer_generation ||
            previous.day != result.day ||
            previous.continuation_index != result.continuation_index ||
            previous.opcode != result.opcode ||
            previous.country_slot != result.country_slot ||
            previous.technology != result.technology ||
            previous.target_handle != result.target_handle ||
            previous.code != result.code ||
            previous.committed_peer_generation !=
                result.committed_peer_generation ||
            previous.technology_flags != result.technology_flags) {
            error = "country_peer_result_duplicate_mismatch";
            return false;
        }
        return true;
    }
    if (!peer_result_identity_matches(pending->second, result, error))
        return false;
    if (result.ok() && pending->second.peer_generation != 0 &&
        (result.committed_peer_generation == 0 ||
         result.committed_peer_generation < pending->second.peer_generation)) {
        error = "country_peer_result_generation_invalid";
        return false;
    }
    _peer_result_cache[result.request_id] = result;
    if (result.code != CountryPeerResultCode::PENDING)
        _peer_pending_intents.erase(pending);
    if (result.code == CountryPeerResultCode::REJECTED)
        remember_peer_rejection(result);
    return true;
}

CountryPeerResult NativeCountryRuntime::apply_peer_intent(
        CountryPeerContext &context, const CountryPeerIntent &intent) {
    CountryPeerResult result;
    result.opcode = intent.opcode;
    result.request_id = intent.request_id;
    result.session_epoch = intent.session_epoch;
    result.country_generation = intent.country_generation;
    result.peer_generation = intent.peer_generation;
    result.day = intent.day;
    result.continuation_index = intent.continuation_index;
    result.country_slot = intent.country_slot;
    result.technology = intent.technology;
    result.target_handle = intent.target_handle;

    auto reject = [&](CountryPeerResultCode code, const char *reason) {
        result.code = code;
        country_peer_copy_reason(result.reason, reason);
        if (code == CountryPeerResultCode::REJECTED)
            remember_peer_rejection(result);
        ++_peer_results_consumed;
        return result;
    };
    const auto intent_identity_matches = [](const CountryPeerIntent &lhs,
                                            const CountryPeerIntent &rhs) {
        return lhs.protocol_version == rhs.protocol_version &&
            lhs.opcode == rhs.opcode && lhs.request_id == rhs.request_id &&
            lhs.session_epoch == rhs.session_epoch &&
            lhs.country_generation == rhs.country_generation &&
            lhs.peer_generation == rhs.peer_generation && lhs.day == rhs.day &&
            lhs.continuation_index == rhs.continuation_index &&
            lhs.country_slot == rhs.country_slot && lhs.technology == rhs.technology &&
            lhs.target_handle == rhs.target_handle &&
            lhs.effect_instance_id == rhs.effect_instance_id &&
            lhs.effect_generation == rhs.effect_generation &&
            lhs.idempotency_key == rhs.idempotency_key;
    };
    const auto existing_context_valid = [&]() {
        if (intent.protocol_version != COUNTRY_PEER_PROTOCOL_VERSION ||
            intent.session_epoch == 0 || intent.session_epoch != _session_epoch ||
            intent.session_epoch != context.session_epoch ||
            intent.day != context.day)
            return false;
        if (intent.target_handle == 0) return true;
        int32_t slot = -1;
        return validate_handle(intent.target_handle, slot) &&
            (intent.country_slot < 0 || slot == intent.country_slot);
    };

    // Existing requests deliberately outlive a Country generation change made
    // by the same research completion. They remain safe because their session,
    // day and target handle are checked here, and no cached result can be
    // substituted for a different request identity.
    const auto pending_intent = _peer_pending_intents.find(intent.request_id);
    if (pending_intent != _peer_pending_intents.end()) {
        if (!existing_context_valid() ||
            !intent_identity_matches(intent, pending_intent->second)) {
            return reject(CountryPeerResultCode::STALE,
                          "country_peer_intent_identity_stale");
        }
        result.code = CountryPeerResultCode::PENDING;
        country_peer_copy_reason(result.reason,
                                 "country_peer_intent_waiting_for_result");
        const CountryPeerTechnologyState *state =
            find_peer_technology_state(context, intent.country_slot,
                                      intent.technology);
        if (state != nullptr) result.technology_flags = state->flags;
        return result;
    }
    const auto cached_result = _peer_result_cache.find(intent.request_id);
    if (cached_result != _peer_result_cache.end()) {
        std::string cache_error;
        if (!existing_context_valid() ||
            !peer_result_identity_matches(intent, cached_result->second,
                                          cache_error)) {
            return reject(CountryPeerResultCode::STALE,
                          "country_peer_intent_identity_stale");
        }
        result = cached_result->second;
        apply_peer_result_to_context(context, result);
        ++_peer_results_consumed;
        return result;
    }
    if (intent.protocol_version != COUNTRY_PEER_PROTOCOL_VERSION ||
        intent.session_epoch == 0 || intent.session_epoch != _session_epoch ||
        intent.session_epoch != context.session_epoch ||
        intent.country_generation == 0 ||
        intent.country_generation != context.country_generation ||
        intent.country_generation != _generation ||
        intent.day != context.day ||
        intent.continuation_index != context.continuation_index) {
        return reject(CountryPeerResultCode::STALE,
                      "country_peer_intent_identity_stale");
    }
    const bool effect_intent =
        intent.opcode == CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT ||
        intent.opcode == CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT ||
        intent.opcode == CountryPeerIntentCode::NOTIFY_ERA_REWARD;
    const bool modifier_intent =
        intent.opcode == CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER;
    const bool economy_intent =
        intent.opcode == CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE;
    if (!effect_intent && !modifier_intent && !economy_intent)
        return reject(CountryPeerResultCode::REJECTED,
                      "country_peer_intent_opcode_invalid");
    const uint64_t expected_peer_generation = effect_intent
        ? context.effect_generation
        : (modifier_intent ? context.modifier_generation :
            (economy_intent ? context.economy_generation : 0));
    if (intent.peer_generation != expected_peer_generation) {
        return reject(CountryPeerResultCode::STALE,
                      "country_peer_intent_peer_generation_stale");
    }

    // A new, identity-valid request for the same logical operation supersedes
    // an earlier-day rejection. The current request rejection, if any, is
    // inserted by reject() below and remains visible.
    clear_peer_rejections_for_retry(intent);

    if (_peer_async_mode) {
        const bool technology_intent = effect_intent || modifier_intent;
        if (technology_intent) {
            int32_t validated_slot = -1;
            if (intent.country_slot < 0 || intent.technology < 0 ||
                intent.technology >= static_cast<int32_t>(_technology_ids.size()) ||
                !validate_handle(intent.target_handle, validated_slot) ||
                validated_slot != intent.country_slot)
                return reject(CountryPeerResultCode::REJECTED,
                              "country_peer_intent_target_invalid");
            const CountryPeerTechnologyState *state =
                find_peer_technology_state(context, intent.country_slot,
                                           intent.technology);
            if (state != nullptr &&
                ((effect_intent && intent.opcode !=
                      CountryPeerIntentCode::NOTIFY_ERA_REWARD &&
                    state->has(COUNTRY_PEER_EFFECT_FIRE_ACKED)) ||
                 (modifier_intent &&
                    state->has(COUNTRY_PEER_MODIFIER_APPLIED)))) {
                result.code = effect_intent
                    ? CountryPeerResultCode::READY
                    : CountryPeerResultCode::APPLIED;
                result.committed_peer_generation = expected_peer_generation;
                result.technology_flags = state->flags;
                ++_peer_results_consumed;
                return result;
            }
        }
        _peer_pending_intents.emplace(intent.request_id, intent);
        _peer_intent_queue.push_back(intent.request_id);
        ++_peer_intents_emitted;
        result.code = CountryPeerResultCode::PENDING;
        country_peer_copy_reason(result.reason, "country_peer_intent_queued");
        return result;
    }
    ++_peer_intents_emitted;
    result = execute_peer_intent_main_thread(intent);
    apply_peer_result_to_context(context, result);
    if (result.code == CountryPeerResultCode::REJECTED)
        remember_peer_rejection(result);
    return result;
}

} // namespace pk

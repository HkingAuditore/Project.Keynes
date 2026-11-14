#include "country_runtime.h"
#include "country_runtime_internal.h"
#include "economy_effect_forward.h"
#include "modifier_api.h"
#include "economy_api.h"
#include "country_host_port.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iterator>
#include <limits>
#include <memory>
#include <numeric>
#include <type_traits>
#include <unordered_set>

#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

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

CountryPeerResult NativeCountryRuntime::execute_peer_intent_main_thread(
        const CountryPeerIntent &intent, bool validate_local_identity) {
    CountryPeerResult result;
    result.protocol_version = intent.protocol_version;
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

    auto reject = [&](const char *reason) {
        result.code = CountryPeerResultCode::REJECTED;
        country_peer_copy_reason(result.reason, reason);
        ++_peer_results_consumed;
        return result;
    };
    if (intent.protocol_version != COUNTRY_PEER_PROTOCOL_VERSION ||
        intent.request_id == 0 || intent.day < 0 ||
        (validate_local_identity &&
         (intent.session_epoch != _session_epoch ||
          intent.country_generation == 0 ||
          intent.country_generation > _generation)))
        return reject("country_peer_adapter_identity_invalid");

    const bool effect_intent =
        intent.opcode == CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT ||
        intent.opcode == CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT ||
        intent.opcode == CountryPeerIntentCode::NOTIFY_ERA_REWARD;
    const bool modifier_intent =
        intent.opcode == CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER;
    const bool economy_intent =
        intent.opcode == CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE;
    if (!effect_intent && !modifier_intent && !economy_intent)
        return reject("country_peer_intent_opcode_invalid");

    if (intent.opcode == CountryPeerIntentCode::NOTIFY_ERA_REWARD) {
        if (!_effect_runtime_enabled || _effect_runtime == nullptr)
            return reject("country_peer_effect_runtime_unavailable");
        if (_effect_runtime->committed_generation() < intent.peer_generation)
            return reject("country_peer_adapter_effect_generation_regressed");
        std::string peer_error;
        if (!_effect_runtime->notify_era_reward_technology_activated_pod(
                intent.target_handle, intent.technology, intent.day,
                peer_error))
            return reject(peer_error.empty() ? "country_peer_era_reward_rejected"
                                             : peer_error.c_str());
        result.code = CountryPeerResultCode::APPLIED;
        result.committed_peer_generation = _effect_runtime->committed_generation();
        ++_peer_results_consumed;
        return result;
    }
    if (intent.opcode == CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE) {
        if (_economy_runtime == nullptr)
            return reject("country_peer_economy_runtime_unavailable");
        if (economy_api::committed_generation(*_economy_runtime) < intent.peer_generation)
            return reject("country_peer_adapter_economy_generation_regressed");
        economy_api::notify_era_milestone_activated(*_economy_runtime, intent.target_handle);
        result.code = CountryPeerResultCode::APPLIED;
        result.committed_peer_generation = economy_api::committed_generation(*_economy_runtime);
        ++_peer_results_consumed;
        return result;
    }

    int32_t validated_slot = -1;
    if (intent.country_slot < 0 || intent.technology < 0 ||
        intent.technology >= static_cast<int32_t>(_technology_ids.size()) ||
        !validate_handle(intent.target_handle, validated_slot) ||
        validated_slot != intent.country_slot)
        return reject("country_peer_intent_target_invalid");

    const std::string &modifier_key =
        intent.technology < static_cast<int32_t>(
            _technology_modifier_definition_keys.size())
        ? _technology_modifier_definition_keys[
              static_cast<size_t>(intent.technology)]
        : std::string{};
    uint8_t technology_flags = 0;
    if (_modifier_runtime != nullptr && modifier_api::configured(*_modifier_runtime) &&
        !modifier_key.empty() && modifier_api::has_technology_effect(*_modifier_runtime,
            intent.target_handle, modifier_key, intent.technology))
        technology_flags |= COUNTRY_PEER_MODIFIER_APPLIED;

    if (intent.opcode == CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT ||
        intent.opcode == CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT) {
        // Route onto the Effect POD both once the worker owns EFFECT and in
        // the ACTIVE grant-pending window before its first committed day.
        // In that window the sync EffectRuntime is no longer driven (the
        // worker Effect stage is), while resolve_pending_country_effect_peers
        // only promotes PENDING results from the POD snapshot. Registering on
        // the sync facade there left the instance unfired and the Country
        // plan waiting on the peer forever (day_wait_peer_stall_timeout),
        // e.g. for a GRANT_TECHNOLOGY submitted on the first game day.
        const bool effect_worker_authoritative = _simulation_host != nullptr &&
            _simulation_host->effect_pod_transport_ready() &&
            (_simulation_host->domain_is_worker_authoritative(
                 RuntimeDomainId::EFFECT) ||
             _simulation_host->domain_grant_pending(RuntimeDomainId::EFFECT));
        {
            // Unconditional entry probe: tells us the adapter actually ran and
            // which branch it picked. Rate limited.
            static int s_entry_left = 30;
            if (s_entry_left-- > 0) {
                UtilityFunctions::print(vformat(
                    "[tech-ack-diag/entry] tech=%d instance=%d eff_gen=%d "
                    "host=%d effect_worker_auth=%d effect_enabled=%d "
                    "effect_runtime=%d branch=%s",
                    intent.technology,
                    static_cast<int64_t>(intent.effect_instance_id),
                    static_cast<int64_t>(intent.effect_generation),
                    _simulation_host != nullptr ? 1 : 0,
                    effect_worker_authoritative ? 1 : 0,
                    _effect_runtime_enabled ? 1 : 0,
                    _effect_runtime != nullptr ? 1 : 0,
                    effect_worker_authoritative ? "pod" : "sync"));
            }
        }
        // F8 ACTIVE: sync EffectRuntime is writeback-only. Route technology
        // registration onto the Effect POD unique-writer and gate READY on
        // the published POD fire ACK — never mutate the sync facade here.
        if (effect_worker_authoritative) {
            if (intent.effect_generation == 0 ||
                intent.effect_generation != static_cast<uint32_t>(
                    intent.target_handle >> 32U) ||
                intent.effect_instance_id == 0)
                return reject("country_peer_effect_generation_invalid");
            const std::string program_key =
                std::string("technology.") +
                _technology_ids[static_cast<size_t>(intent.technology)];
            const int32_t program_id =
                _simulation_host->effect_pod_program_id_for_key(
                    program_key.c_str());
            if (program_id < 0) {
                // Catalog has no Effect program for this technology. Treat as
                // fire-acked so activation is not pinned forever.
                technology_flags |= COUNTRY_PEER_EFFECT_EXISTS |
                    COUNTRY_PEER_EFFECT_FIRE_ACKED;
                result.code = CountryPeerResultCode::READY;
                result.technology_flags = technology_flags;
                result.committed_peer_generation = intent.peer_generation;
                ++_peer_results_consumed;
                return result;
            }
            std::string peer_error;
            if (!_simulation_host->ensure_effect_pod_technology_instance(
                    static_cast<int64_t>(intent.effect_instance_id),
                    intent.effect_generation, program_id,
                    intent.target_handle, intent.effect_generation,
                    intent.day, peer_error)) {
                return reject(peer_error.empty()
                    ? "country_peer_effect_pod_queue_rejected"
                    : peer_error.c_str());
            }
            technology_flags |= COUNTRY_PEER_EFFECT_EXISTS;
            if (_simulation_host->effect_pod_instance_fire_acked(
                    static_cast<int64_t>(intent.effect_instance_id),
                    intent.effect_generation)) {
                technology_flags |= COUNTRY_PEER_EFFECT_FIRE_ACKED;
                result.code = CountryPeerResultCode::READY;
            } else {
                static int s_pod_left = 30;
                if (s_pod_left-- > 0) {
                    UtilityFunctions::print(vformat("[tech-ack-diag/pod] %s",
                        String(_simulation_host
                            ->describe_effect_pod_technology_state(
                                static_cast<int64_t>(intent.effect_instance_id),
                                intent.effect_generation, program_id,
                                intent.technology).c_str())));
                }
                result.code = CountryPeerResultCode::PENDING;
            }
            result.technology_flags = technology_flags;
            result.committed_peer_generation = intent.peer_generation;
            ++_peer_results_consumed;
            return result;
        }
        if (!_effect_runtime_enabled || _effect_runtime == nullptr)
            return reject("country_peer_effect_runtime_unavailable");
        if (_effect_runtime->committed_generation() < intent.peer_generation)
            return reject("country_peer_adapter_effect_generation_regressed");
        if (intent.effect_generation == 0 ||
            intent.effect_generation != static_cast<uint32_t>(
                intent.target_handle >> 32U) ||
            intent.effect_instance_id == 0)
            return reject("country_peer_effect_generation_invalid");
        // Ask whichever side owns EFFECT. The helper reports "unknown" through
        // its return value; unknown is treated as absent, which is what the old
        // unconditional `has_instance_pod` effectively did on every path and
        // keeps NUDGE's rejection token unchanged.
        bool exists = false;
        effect_pod_instance_exists(
            _effect_runtime, _effect_forwarder,
            static_cast<int64_t>(intent.effect_instance_id),
            intent.effect_generation, exists);
        if (!exists) {
            if (intent.opcode == CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT)
                return reject("country_peer_effect_instance_missing");
            std::string peer_error;
            // Same door as the bootstrap install. On the legacy authority the
            // forwarder delegates to upsert_instance_pod (and shadow-mirrors to
            // the worker); if EFFECT flipped to the worker between the guard
            // above and here, the row still lands on the side that owns it
            // instead of being erased by the next snapshot.
            if (!effect_pod_upsert(
                    _effect_runtime, _effect_forwarder,
                    static_cast<int64_t>(intent.effect_instance_id),
                    std::string("technology.") +
                        _technology_ids[static_cast<size_t>(intent.technology)],
                    intent.effect_generation, 0x54454348,
                    intent.technology + 1, intent.target_handle,
                    intent.target_handle, intent.effect_generation, 0,
                    intent.day, -1, true, peer_error))
                return reject(peer_error.empty()
                    ? "country_peer_effect_upsert_rejected"
                    : peer_error.c_str());
        }
        if (!_effect_runtime->instance_fire_acked_pod(
                static_cast<int64_t>(intent.effect_instance_id),
                intent.effect_generation) &&
            !_effect_runtime->nudge_unacked_instance_pod(
                static_cast<int64_t>(intent.effect_instance_id),
                intent.effect_generation, intent.day))
            return reject("country_peer_effect_nudge_rejected");

        technology_flags |= COUNTRY_PEER_EFFECT_EXISTS;
        if (_effect_runtime->instance_fire_acked_pod(
                static_cast<int64_t>(intent.effect_instance_id),
                intent.effect_generation)) {
            technology_flags |= COUNTRY_PEER_EFFECT_FIRE_ACKED;
            result.code = CountryPeerResultCode::READY;
        } else {
            static int s_sync_left = 30;
            if (s_sync_left-- > 0) {
                UtilityFunctions::print(vformat(
                    "[tech-ack-diag/sync] tech=%d instance=%d gen=%d "
                    "existed=%d day=%d committed_gen=%d",
                    intent.technology,
                    static_cast<int64_t>(intent.effect_instance_id),
                    static_cast<int64_t>(intent.effect_generation),
                    exists ? 1 : 0, intent.day,
                    static_cast<int64_t>(
                        _effect_runtime->committed_generation())));
            }
            result.code = CountryPeerResultCode::PENDING;
        }
        result.technology_flags = technology_flags;
        result.committed_peer_generation = _effect_runtime->committed_generation();
        ++_peer_results_consumed;
        return result;
    }

    if (_modifier_runtime == nullptr || !modifier_api::configured(*_modifier_runtime) ||
        modifier_key.empty())
        return reject("country_peer_modifier_runtime_unavailable");
    if (modifier_api::domain_snapshot_version(*_modifier_runtime, ModifierApi::COUNTRY) <
        intent.peer_generation)
        return reject("country_peer_adapter_modifier_generation_regressed");
    if ((technology_flags & COUNTRY_PEER_MODIFIER_APPLIED) == 0) {
        std::string peer_error;
        if (!modifier_api::apply_technology_effect(*_modifier_runtime,
                intent.target_handle, modifier_key, intent.technology,
                intent.day, peer_error))
            return reject(peer_error.empty()
                ? "country_peer_modifier_apply_rejected"
                : peer_error.c_str());
        technology_flags |= COUNTRY_PEER_MODIFIER_APPLIED;
    }
    result.code = CountryPeerResultCode::APPLIED;
    result.technology_flags = technology_flags;
    result.committed_peer_generation =
        modifier_api::domain_snapshot_version(*_modifier_runtime, ModifierApi::COUNTRY);
    ++_peer_results_consumed;
    return result;
}

CountryPeerResult NativeCountryRuntime::execute_peer_intent_from_worker(
        const CountryPeerIntent &intent) {
    return execute_peer_intent_main_thread(intent, false);
}

bool NativeCountryRuntime::service_peer_intents_main_thread(
        int32_t max_intents, PeerAdapterServiceReport &out,
        std::string &error) {
    out = PeerAdapterServiceReport{};
    error.clear();
    drain_effect_host_command_receipts();
    if (!_configured || !_bootstrapped || _mode == MODE_OFF) {
        error = "country_peer_adapter_runtime_unavailable";
        return false;
    }
    if (!_peer_async_mode) {
        error = "country_peer_adapter_async_mode_required";
        return false;
    }
    if (max_intents <= 0 || max_intents > 4096) {
        error = "country_peer_adapter_limit_invalid";
        return false;
    }

    std::vector<uint64_t> request_ids;
    request_ids.reserve(_peer_pending_intents.size());
    for (const auto &entry : _peer_pending_intents)
        request_ids.push_back(entry.first);
    std::sort(request_ids.begin(), request_ids.end());
    if (request_ids.size() > static_cast<size_t>(max_intents))
        request_ids.resize(static_cast<size_t>(max_intents));

    for (const uint64_t request_id : request_ids) {
        const auto found = _peer_pending_intents.find(request_id);
        if (found == _peer_pending_intents.end()) continue;
        const CountryPeerIntent intent = found->second;
        _peer_intent_queue.erase(std::remove(_peer_intent_queue.begin(),
                                            _peer_intent_queue.end(), request_id),
                                 _peer_intent_queue.end());
        ++out.inspected;
        out.last_request_id = request_id;
        switch (intent.opcode) {
        case CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT:
        case CountryPeerIntentCode::NUDGE_TECHNOLOGY_EFFECT:
        case CountryPeerIntentCode::NOTIFY_ERA_REWARD:
            ++out.effect_intents;
            break;
        case CountryPeerIntentCode::APPLY_TECHNOLOGY_MODIFIER:
            ++out.modifier_intents;
            break;
        case CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE:
            ++out.economy_intents;
            break;
        }

        const CountryPeerResult result = execute_peer_intent_main_thread(intent);
        out.last_reason = result.reason.data();
        switch (result.code) {
        case CountryPeerResultCode::READY:
        case CountryPeerResultCode::APPLIED:
            ++out.completed;
            break;
        case CountryPeerResultCode::PENDING:
            ++out.pending;
            break;
        case CountryPeerResultCode::REJECTED:
        case CountryPeerResultCode::STALE:
            ++out.rejected;
            break;
        }
        std::string submit_error;
        if (!submit_peer_result(result, submit_error)) {
            error = submit_error.empty()
                ? "country_peer_adapter_result_submit_failed"
                : submit_error;
            return false;
        }
        if (_simulation_host != nullptr && !_sync_store_writes_forbidden &&
            _simulation_host->country_pod_configured() &&
            result.code != CountryPeerResultCode::PENDING) {
            std::string mirror_error;
            _simulation_host->mirror_country_peer_result(result, mirror_error);
        }
    }
    return true;
}
bool NativeCountryRuntime::peer_protocol_self_test(std::string &error) {
    error.clear();
    if (!_configured || !_bootstrapped || _mode == MODE_OFF ||
        _command_batch.active || _boundary_seal_active ||
        !_pending_commands.empty()) {
        error = "country_peer_protocol_test_requires_idle_runtime";
        return false;
    }
    CountryPeerContext context;
    if (!capture_peer_context(
            std::max<int64_t>(0, _last_committed_day),
            _reference_continuation_index, context, error))
        return false;
    if (context.protocol_version != COUNTRY_PEER_PROTOCOL_VERSION ||
        context.session_epoch != _session_epoch ||
        context.country_generation != _generation ||
        context.research_cost_factor.size() != _countries.active.size() ||
        context.research_efficiency.size() != _countries.active.size() * 4u) {
        error = "country_peer_protocol_test_context_shape";
        return false;
    }
    int32_t slot = -1;
    for (int32_t candidate = 0;
         candidate < static_cast<int32_t>(_countries.active.size());
         ++candidate) {
        if (_countries.active[static_cast<size_t>(candidate)] != 0) {
            slot = candidate;
            break;
        }
    }
    if (slot < 0) {
        error = "country_peer_protocol_test_country_missing";
        return false;
    }
    const int32_t technology = _technology_ids.empty() ? -1 : 0;
    if (technology < 0) {
        error = "country_peer_protocol_test_technology_missing";
        return false;
    }
    const CountryPeerIntent first = make_peer_intent(
        context, CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT,
        slot, technology, context.day);
    const CountryPeerIntent second = make_peer_intent(
        context, CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT,
        slot, technology, context.day);
    if (first.request_id == 0 || first.request_id != second.request_id ||
        first.idempotency_key != second.idempotency_key) {
        error = "country_peer_protocol_test_request_identity";
        return false;
    }
    CountryPeerIntent stale_session = first;
    ++stale_session.session_epoch;
    const CountryPeerResult stale_session_result = apply_peer_intent(
        context, stale_session);
    if (stale_session_result.code != CountryPeerResultCode::STALE ||
        std::string(stale_session_result.reason.data()) !=
            "country_peer_intent_identity_stale") {
        error = "country_peer_protocol_test_session_rejection";
        return false;
    }
    CountryPeerIntent stale_generation = first;
    ++stale_generation.peer_generation;
    const CountryPeerResult stale_generation_result = apply_peer_intent(
        context, stale_generation);
    if (stale_generation_result.code != CountryPeerResultCode::STALE ||
        std::string(stale_generation_result.reason.data()) !=
            "country_peer_intent_peer_generation_stale") {
        error = "country_peer_protocol_test_peer_generation_rejection";
        return false;
    }

    auto result_for = [](const CountryPeerIntent &intent,
                         CountryPeerResultCode code) {
        CountryPeerResult result;
        result.code = code;
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
        return result;
    };
    set_peer_async_mode(true);
    const auto async_failure = [&](const char *reason) {
        clear_peer_protocol_state();
        error = reason;
        return false;
    };
    CountryPeerContext async_context = context;
    const CountryPeerIntent queued_intent = make_peer_intent(
        async_context, CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT,
        slot, technology, async_context.day);
    const CountryPeerResult queued_result = apply_peer_intent(
        async_context, queued_intent);
    if (queued_result.code != CountryPeerResultCode::PENDING ||
        pending_peer_intent_count() != 1)
        return async_failure("country_peer_protocol_test_async_queue");
    CountryPeerIntent polled_intent;
    if (!poll_peer_intent(polled_intent) ||
        polled_intent.request_id != queued_intent.request_id ||
        poll_peer_intent(polled_intent))
        return async_failure("country_peer_protocol_test_async_poll");

    CountryPeerResult unknown_result = result_for(
        queued_intent, CountryPeerResultCode::READY);
    unknown_result.request_id ^= 0x1ULL;
    if (unknown_result.request_id == 0) unknown_result.request_id = 1;
    std::string submit_error;
    if (submit_peer_result(unknown_result, submit_error) ||
        submit_error != "country_peer_result_request_unknown")
        return async_failure("country_peer_protocol_test_unknown_result");

    CountryPeerResult stale_result = result_for(
        queued_intent, CountryPeerResultCode::READY);
    ++stale_result.session_epoch;
    if (submit_peer_result(stale_result, submit_error) ||
        submit_error != "country_peer_result_identity_mismatch")
        return async_failure("country_peer_protocol_test_stale_result");
    stale_result = result_for(queued_intent, CountryPeerResultCode::READY);
    stale_result.peer_generation ^= 0x1ULL;
    if (submit_peer_result(stale_result, submit_error) ||
        submit_error != "country_peer_result_identity_mismatch")
        return async_failure("country_peer_protocol_test_stale_generation_result");

    CountryPeerResult acknowledged = result_for(
        queued_intent, CountryPeerResultCode::READY);
    acknowledged.committed_peer_generation = queued_intent.peer_generation == 0
        ? 0 : queued_intent.peer_generation + 1u;
    acknowledged.technology_flags = COUNTRY_PEER_EFFECT_EXISTS |
        COUNTRY_PEER_EFFECT_FIRE_ACKED;
    if (!submit_peer_result(acknowledged, submit_error) ||
        !submit_peer_result(acknowledged, submit_error) ||
        pending_peer_intent_count() != 0)
        return async_failure("country_peer_protocol_test_duplicate_ack");

    CountryPeerContext continuation_context = context;
    ++continuation_context.country_generation;
    const CountryPeerIntent replayed_intent = make_peer_intent(
        continuation_context,
        CountryPeerIntentCode::ENSURE_TECHNOLOGY_EFFECT,
        slot, technology, continuation_context.day);
    const CountryPeerResult replayed_result = apply_peer_intent(
        continuation_context, replayed_intent);
    if (replayed_intent.request_id != queued_intent.request_id ||
        replayed_result.code != CountryPeerResultCode::READY ||
        !replayed_result.has(COUNTRY_PEER_EFFECT_FIRE_ACKED))
        return async_failure("country_peer_protocol_test_same_day_continuation");

    const CountryPeerIntent rejected_intent = make_peer_intent(
        async_context, CountryPeerIntentCode::NOTIFY_ECONOMY_MILESTONE,
        slot, technology, async_context.day);
    if (apply_peer_intent(async_context, rejected_intent).code !=
            CountryPeerResultCode::PENDING ||
        !poll_peer_intent(polled_intent) ||
        polled_intent.request_id != rejected_intent.request_id)
        return async_failure("country_peer_protocol_test_rejection_queue");
    CountryPeerResult rejected = result_for(
        rejected_intent, CountryPeerResultCode::REJECTED);
    country_peer_copy_reason(rejected.reason, "peer_rejected_for_test");
    if (!submit_peer_result(rejected, submit_error) ||
        apply_peer_intent(async_context, rejected_intent).ok())
        return async_failure("country_peer_protocol_test_rejected_result");
    clear_peer_protocol_state();
    return true;
}

} // namespace pk

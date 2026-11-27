#include "country_runtime.h"
#include "country_runtime_internal.h"
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

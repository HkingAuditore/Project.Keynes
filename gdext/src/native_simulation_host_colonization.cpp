#include "native_simulation_host.h"

#include "economy_api.h"
#include "runtime_economy_boundary_request.h"
#include "runtime_vision.h"

#include <algorithm>

namespace pk {

bool NativeSimulationHost::vision_executor_active() const noexcept {
    return bool(latest_vision()) &&
        _requested_authority_mask.load(std::memory_order_acquire) == RUNTIME_ALL_DOMAIN_MASK &&
        _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
        _state.load(std::memory_order_acquire) != RuntimeWorkerState::STOPPED;
}

godot::Dictionary NativeSimulationHost::submit_economy_boundary_request(
        std::shared_ptr<RuntimeEconomyBoundaryRequest> request) {
    const auto available = [&] {
        const auto state = _state.load(std::memory_order_acquire);
        return vision_executor_active() && state != RuntimeWorkerState::FAULTED &&
            state != RuntimeWorkerState::STOPPING && !_stop_requested.load(std::memory_order_acquire);
    };
    godot::Dictionary out;
    out["ok"] = false;
    out["admitted"] = false;
    out["code"] = "colonization_executor_unavailable";
    if (request->command()) {
        int64_t day = std::max<int64_t>(0, request->effective_day);
        {
            auto admission = admit_command(day);
            if (!admission.accepted() || !available()) return out;
            std::lock_guard<std::mutex> control(_control_mutex);
            if (_economy_boundary_requests.size() == RUNTIME_COMMAND_QUEUE_CAPACITY) {
                out["code"] = "economy_command_queue_full";
                return out;
            }
            request->effective_day = day;
            _economy_boundary_requests.push_back(request);
        }
        _control_cv.notify_one();
        out["ok"] = true;
        out["admitted"] = true;
        out["pending"] = true;
        out["queued"] = true;
        using Kind = RuntimeEconomyBoundaryRequest::Kind;
        out["code"] = request->kind == Kind::START ? "colonization_queued" :
            request->kind == Kind::CANCEL ? "colonization_cancel_queued" : "queued";
        out["effective_day"] = day;
        out["sequence"] = request->sequence;
        return out;
    }
    std::shared_ptr<const RuntimeEconomyBoundaryRequest> published;
    bool queued = false;
    {
        std::lock_guard<std::mutex> control(_control_mutex);
        if (!available()) return out;
        const auto existing = std::find_if(_colonization_read_results.begin(),
            _colonization_read_results.end(), [&](const auto &entry) {
                return entry->same_query(*request);
            });
        // A request completed between frames may already be older than the
        // latest commit. Deliver its snapshot once before requesting a refresh.
        if (existing != _colonization_read_results.end() && (*existing)->query_day >= 0 &&
                (!(*existing)->result_seen || (*existing)->query_day >= committed_day_value())) {
            (*existing)->result_seen = true;
            published = *existing;
        } else if ((existing == _colonization_read_results.end() || (*existing)->query_day >= 0) &&
                _economy_boundary_requests.size() < RUNTIME_COMMAND_QUEUE_CAPACITY) {
            constexpr size_t read_capacity = 128;
            if (existing != _colonization_read_results.end()) _colonization_read_results.erase(existing);
            if (_colonization_read_results.size() == read_capacity) {
                const auto ready = std::find_if(_colonization_read_results.begin(),
                    _colonization_read_results.end(), [](const auto &entry) {
                        return entry->query_day >= 0;
                    });
                if (ready != _colonization_read_results.end()) _colonization_read_results.erase(ready);
            }
            if (_colonization_read_results.size() < read_capacity) {
                _colonization_read_results.push_back(request);
                _economy_boundary_requests.push_back(std::move(request));
                queued = true;
            }
        }
    }
    if (published) return published->result.duplicate(true);
    if (queued) _control_cv.notify_one();
    out["pending"] = true;
    out["busy"] = true;
    out["code"] = "economy_busy_retry";
    return out;
}

const std::vector<uint8_t> *NativeSimulationHost::colonization_visibility() const {
    if (!_executor_vision || !_executor_vision->frame) return nullptr;
    // 开拓可以前往曾经探索过、但当前观察源已经看不到的格子。
    // 未探索格仍为 0，路线搜索因此继续阻止盲目开拓。
    return _executor_vision->fog_enabled ? &_executor_vision->frame->explored : &_executor_vision->all_visible;
}

bool NativeSimulationHost::service_economy_boundary_requests() {
    {
        std::lock_guard<std::mutex> control(_control_mutex);
        if (_economy_boundary_requests.empty()) return false;
    }
    std::lock_guard<std::mutex> boundary(_economy_authority_boundary_mutex);
    std::deque<std::shared_ptr<RuntimeEconomyBoundaryRequest>> requests;
    {
        std::lock_guard<std::mutex> control(_control_mutex);
        requests.swap(_economy_boundary_requests);
    }
    if (requests.empty()) return false;

    {
        auto *economy = _economy_production_runtime;
        const auto &vision = *_executor_vision;
        const auto &frame = *vision.frame;
        const auto &visible = frame.fog_enabled ? frame.explored : vision.all_visible;
        for (const auto &request : requests) {
            auto &r = *request;
            if (economy == nullptr || economy_api::epoch_active(*economy)) {
                r.result["ok"] = false;
                r.result["busy"] = economy != nullptr;
                r.result["code"] = economy ? "economy_busy_retry" : "economy_not_available";
                continue;
            }
            switch (r.kind) {
            case RuntimeEconomyBoundaryRequest::Kind::QUOTES:
                r.result = economy_api::family_colonization_quotes(*economy,
                    r.country_handle, r.target_cell, r.family_handle, r.source_cell,
                    r.offset, r.limit, visible.data(), visible.size(), frame.revision);
                break;
            case RuntimeEconomyBoundaryRequest::Kind::QUOTE_DETAIL:
                r.result = economy_api::family_colonization_quote_detail(*economy, r.quote_token, r.population);
                break;
            case RuntimeEconomyBoundaryRequest::Kind::START:
                r.result = economy_api::submit_family_colonization_start(*economy,
                    r.country_handle, r.family_handle, r.source_cell, r.target_cell,
                    r.population, r.quote_token, r.effective_day, r.sequence,
                    visible.data(), visible.size(), frame.revision, true);
                break;
            case RuntimeEconomyBoundaryRequest::Kind::CANCEL:
                r.result = economy_api::submit_family_colonization_cancel(*economy,
                    r.country_handle, r.subject_id, r.effective_day, r.sequence);
                break;
            case RuntimeEconomyBoundaryRequest::Kind::FOUNDING_CHOICE: {
                const auto confirmation = std::atomic_load(&_player_confirmation.published);
                const bool stopped_for_family = confirmation && confirmation->family_offer_offset >= 0;
                r.result = economy_api::submit_family_founding_choice(*economy,
                    r.subject_id, r.offer_generation, r.choice, r.effective_day, r.sequence,
                    stopped_for_family && r.effective_day == committed_day_value() + 1);
                if (bool(r.result.get("ok", false))) admit_player_response_through(r.effective_day);
                break;
            }
            case RuntimeEconomyBoundaryRequest::Kind::BUILD_CANAL:
                r.result = economy_api::queue_canal_construction(*economy,
                    r.country_handle, r.quote_token, r.effective_day, r.sequence);
                break;
            }
        }
    }
    for (const auto &request : requests) {
        if (const char *command = request->command()) {
            if (request->kind == RuntimeEconomyBoundaryRequest::Kind::FOUNDING_CHOICE &&
                    bool(request->result.get("ok", false))) continue;
            request->result["country_handle"] = request->country_handle;
            if (bool(request->result.get("ok", false))) request->result["effective_day"] = request->effective_day;
            publish_boundary_command_result(command, request->sequence, request->result);
        } else {
            request->result["read_view_day"] = committed_day_value();
        }
    }
    {
        std::lock_guard<std::mutex> control(_control_mutex);
        for (const auto &request : requests) {
            if (request->command()) continue;
            request->query_day = committed_day_value();
            _colonization_quotes_ready = true;
        }
    }
    return true;
}

} // namespace pk

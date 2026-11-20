#include "native_simulation_host.h"

#include "economy_api.h"
#include "runtime_economy_boundary_request.h"
#include "runtime_vision.h"

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
            auto admission = lock_command_admission(day);
            if (!admission.owns_lock() || !available()) return out;
            std::lock_guard<std::mutex> control(_control_mutex);
            if (_economy_boundary_requests.size() == RUNTIME_COMMAND_QUEUE_CAPACITY) {
                out["code"] = "economy_command_queue_full";
                return out;
            }
            request->effective_day = day;
            _economy_boundary_requests.push_back(request);
        }
        if (inline_daily_mode()) service_economy_boundary_requests();
        else _control_cv.notify_one();
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
    std::unique_lock<std::mutex> control(_control_mutex);
    if (!available()) return out;
    _economy_boundary_requests.push_back(request);
    if (inline_daily_mode()) {
        control.unlock();
        service_economy_boundary_requests();
        return request->result;
    }
    _control_cv.notify_all();
    _control_cv.wait(control, [&] { return request->done || !available(); });
    return request->done ? request->result : out;
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
        const auto &visible = frame.fog_enabled ? frame.visible : vision.all_visible;
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
            case RuntimeEconomyBoundaryRequest::Kind::FOUNDING_CHOICE:
                r.result = economy_api::submit_family_founding_choice(*economy,
                    r.subject_id, r.offer_generation, r.choice, r.effective_day, r.sequence);
                break;
            case RuntimeEconomyBoundaryRequest::Kind::BUILD_CANAL:
                r.result = economy_api::queue_canal_construction(*economy,
                    r.country_handle, r.quote_token, r.effective_day, r.sequence);
                break;
            }
        }
    }
    for (const auto &request : requests) {
        if (const char *command = request->command()) {
            request->result["country_handle"] = request->country_handle;
            if (bool(request->result.get("ok", false))) request->result["effective_day"] = request->effective_day;
            publish_boundary_command_result(command, request->sequence, request->result);
        }
    }
    {
        std::lock_guard<std::mutex> control(_control_mutex);
        for (const auto &request : requests) request->done = true;
    }
    _control_cv.notify_all();
    return true;
}

} // namespace pk

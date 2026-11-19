#include "native_simulation_host.h"

#include "economy_runtime.h"
#include "runtime_colonization_request.h"
#include "runtime_vision.h"

namespace pk {

bool NativeSimulationHost::vision_executor_active() const noexcept {
    return bool(latest_vision()) &&
        _requested_authority_mask.load(std::memory_order_acquire) == RUNTIME_ALL_DOMAIN_MASK &&
        _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
        _state.load(std::memory_order_acquire) != RuntimeWorkerState::STOPPED;
}

bool NativeSimulationHost::submit_colonization_request(
        std::shared_ptr<RuntimeColonizationRequest> request) {
    std::unique_lock<std::mutex> control(_control_mutex);
    const auto available = [&] {
        const auto state = _state.load(std::memory_order_acquire);
        return vision_executor_active() && state != RuntimeWorkerState::FAULTED &&
            state != RuntimeWorkerState::STOPPING && !_stop_requested.load(std::memory_order_acquire);
    };
    if (!available()) return false;
    _colonization_requests.push_back(request);
    if (inline_daily_mode()) {
        control.unlock();
        service_colonization_requests();
        return request->done;
    }
    _control_cv.notify_all();
    _control_cv.wait(control, [&] { return request->done || !available(); });
    return request->done;
}

bool NativeSimulationHost::service_colonization_requests() {
    std::deque<std::shared_ptr<RuntimeColonizationRequest>> requests;
    {
        std::lock_guard<std::mutex> control(_control_mutex);
        requests.swap(_colonization_requests);
    }
    if (requests.empty()) return false;

    {
        std::lock_guard<std::mutex> boundary(_economy_authority_boundary_mutex);
        auto *economy = _economy_production_runtime;
        const auto &vision = *_executor_vision;
        const auto &frame = *vision.frame;
        const auto &visible = frame.fog_enabled ? frame.visible : vision.all_visible;
        for (const auto &request : requests) {
            auto &r = *request;
            if (economy == nullptr || economy->epoch_active()) {
                r.result["ok"] = false;
                r.result["busy"] = economy != nullptr;
                r.result["code"] = economy ? "economy_busy_retry" : "economy_not_available";
                continue;
            }
            switch (r.kind) {
            case RuntimeColonizationRequest::Kind::QUOTES:
                r.result = economy->family_colonization_quotes(
                    r.country_handle, r.target_cell, r.family_handle, r.source_cell,
                    r.offset, r.limit, visible.data(), visible.size(), frame.revision);
                break;
            case RuntimeColonizationRequest::Kind::QUOTE_DETAIL:
                r.result = economy->family_colonization_quote_detail(r.quote_token, r.population);
                break;
            case RuntimeColonizationRequest::Kind::START:
                r.result = economy->submit_family_colonization_start(
                    r.country_handle, r.family_handle, r.source_cell, r.target_cell,
                    r.population, r.quote_token, r.effective_day, r.sequence,
                    visible.data(), visible.size(), frame.revision, true);
                break;
            }
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

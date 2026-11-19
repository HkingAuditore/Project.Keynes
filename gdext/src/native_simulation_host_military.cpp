#include "native_simulation_day_context.h"
#include "native_simulation_host_military.h"
#include "runtime_vision.h"
#include "world_ext.h"

#include <atomic>
#include <utility>

namespace pk {

void NativeSimulationHost::attach_military(std::shared_ptr<NativeMilitaryRuntime> military) {
    _executor_military = std::move(military);
    if (_executor_military) {
        _executor_military->_runtime_host = this;
        if (_has_pending_restore)
            _executor_military->restore_terrain(_pending_restore_bundle.military_terrain_bytes);
        _executor_military->publish(_executor_military->last_result);
    }
}

bool NativeSimulationHost::military_executor_active() const noexcept {
    return _executor_military && _state.load(std::memory_order_acquire) != RuntimeWorkerState::STOPPED &&
        _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
        _requested_authority_mask.load(std::memory_order_acquire) == RUNTIME_ALL_DOMAIN_MASK;
}

bool NativeSimulationHost::submit_military_commands(std::shared_ptr<MilitaryCommandBatch> batch) {
    std::unique_lock<std::mutex> control(_control_mutex);
    const auto available = [&] {
        const auto state = _state.load(std::memory_order_acquire);
        return military_executor_active() && state != RuntimeWorkerState::FAULTED &&
            state != RuntimeWorkerState::STOPPING && !_stop_requested.load(std::memory_order_acquire);
    };
    if (!available()) return false;
    batch->day = command_seal_day();
    _military_commands.push_back(batch);
    if (inline_daily_mode()) {
        control.unlock();
        service_military_commands();
        return batch->done;
    }
    _control_cv.notify_all();
    _control_cv.wait(control, [&] { return batch->done || !available(); });
    return batch->done;
}

bool NativeSimulationHost::service_military_commands() {
    std::deque<std::shared_ptr<MilitaryCommandBatch>> pending;
    {
        std::lock_guard<std::mutex> control(_control_mutex);
        pending.swap(_military_commands);
    }
    if (pending.empty()) return false;
    auto &military = *_executor_military;
    military.country_state = _country_pod_authority.borrow_state();
    for (const auto &batch : pending) military.admit(*batch);
    military.publish(military.last_result);
    {
        std::lock_guard<std::mutex> control(_control_mutex);
        for (const auto &batch : pending) batch->done = true;
    }
    _control_cv.notify_all();
    return true;
}

const char *NativeSimulationHost::stage_military(DayExecution &day) {
    if (!_executor_military || day.commit.completed_domain_mask != RUNTIME_ALL_DOMAIN_MASK ||
        _requested_authority_mask.load(std::memory_order_acquire) != RUNTIME_ALL_DOMAIN_MASK) return nullptr;
    auto &military = *_executor_military;
    military.country_state = _country_pod_authority.borrow_state();
    military._modifier_runtime = _economy_modifier_view;
    const auto index = day.plan.context.day;
    if (day.environment != nullptr) {
        if (const char *error = military.prepare_day(*day.environment)) return error;
    }
    if (_executor_vision) {
        const auto &vision = *_executor_vision->frame;
        military.prepare_exploration(_executor_vision->player_slot, vision.explored, index, vision.revision);
    }
    if (military.should_run(index)) {
        military.last_result = military.run_day(index);
        if (!static_cast<bool>(military.last_result.get("ok", false)) &&
            godot::String(military.last_result.get("reason", "")) != "military_intent_submit_failed")
            return "military_stage_failed";
    } else {
        military.last_result = godot::Dictionary();
        military.last_result["ok"] = true;
        military.last_result["path"] = "native_military_skip";
        military.last_result["day_index"] = index;
    }
    return military.forward_events(index) ? nullptr : "military_events_submission_failed";
}

void NativeSimulationHost::publish_military_day() {
    if (!military_executor_active()) return;
    auto &military = *_executor_military;
    military.publish(military.last_result);
}

} // namespace pk

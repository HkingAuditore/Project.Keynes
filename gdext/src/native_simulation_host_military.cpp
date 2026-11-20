#include "native_simulation_day_context.h"
#include "native_simulation_host_military.h"
#include "pk_log.h"
#include "runtime_vision.h"
#include "world_ext.h"

#include <algorithm>
#include <atomic>
#include <utility>

namespace pk {

void NativeSimulationHost::sample_narrative_military(NarrativeCountryView &out) const {
    if (_executor_military) sample_narrative_military_country(_executor_military->core(), out);
}

void NativeSimulationHost::attach_military(std::shared_ptr<NativeMilitaryRuntime> military) {
    _executor_military = std::move(military);
    if (_executor_military) {
        _executor_military->_runtime_host = this;
        if (_has_pending_restore &&
                (_pending_restore_bundle.section_mask & RUNTIME_SAVE_SECTION_MILITARY_TERRAIN) != 0) {
            std::string error;
            if (!_executor_military->restore_terrain(_pending_restore_bundle.military_terrain_bytes, error))
                log_error("military terrain restore: %s", error.c_str());
        }
        _executor_military->publish(_executor_military->last_result);
    }
}

bool NativeSimulationHost::military_executor_active() const noexcept {
    return _executor_military && _state.load(std::memory_order_acquire) != RuntimeWorkerState::STOPPED &&
        _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
        _requested_authority_mask.load(std::memory_order_acquire) == RUNTIME_ALL_DOMAIN_MASK;
}

bool NativeSimulationHost::submit_military_commands(std::shared_ptr<MilitaryCommandBatch> batch) {
    {
        int64_t day = 0;
        auto admission = admit_command(day);
        if (!admission.accepted() || !military_executor_active()) return false;
        batch->committed_at_admission = committed_day_value();
        batch->frozen_at_admission = frozen_command_day();
        batch->day = std::max({day, batch->committed_at_admission + 1, batch->frozen_at_admission + 1});
        if (!_executor_military->stamp_commands(*batch)) return true;
        std::lock_guard<std::mutex> control(_control_mutex);
        if (_military_commands.size() == RUNTIME_COMMAND_QUEUE_CAPACITY) return false;
        _military_commands.push_back(std::make_shared<MilitaryCommandBatch>(*batch));
    }
    if (inline_daily_mode()) service_military_commands();
    else _control_cv.notify_one();
    return true;
}

bool NativeSimulationHost::service_military_commands() {
    {
        std::lock_guard<std::mutex> control(_control_mutex);
        if (_military_commands.empty()) return false;
    }
    std::lock_guard<std::mutex> boundary(_economy_authority_boundary_mutex);
    std::deque<std::shared_ptr<MilitaryCommandBatch>> pending;
    {
        std::lock_guard<std::mutex> control(_control_mutex);
        pending.swap(_military_commands);
    }
    if (pending.empty()) return false;
    auto &military = *_executor_military;
    military.country_state = _country_pod_authority.borrow_state();
    for (const auto &batch : pending) {
        military.admit(*batch);
        for (const auto &row : batch->rows) {
            if (row.effective_day < 0 || row.error.empty()) continue;
            godot::Dictionary result;
            result["ok"] = false;
            result["code"] = godot::String(row.error.c_str());
            publish_boundary_command_result(row.command_name.c_str(), row.caller_sequence, std::move(result));
        }
    }
    military.publish(military.last_result);
    return true;
}

const char *NativeSimulationHost::preflight_military_construction(
        uint64_t country, int32_t cell, int32_t type, bool demolishing,
        int64_t day, int32_t &building, int32_t &slot) const {
    const auto *state = _country_pod_authority.borrow_state();
    if (!_executor_military || state == nullptr || !on_worker_thread())
        return "military_executor_unavailable";
    return _executor_military->preflight_construction(
        *state, country, cell, type, demolishing, day, building, slot);
}

void NativeSimulationHost::commit_military_construction(
        int32_t cell, int32_t building, int32_t slot, int64_t day, int64_t ready_day) {
    _executor_military->commit_construction(cell, building, slot, day, ready_day);
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
        for (const auto &rejection : military.take_player_rejections()) {
            godot::Dictionary result;
            result["ok"] = false;
            result["code"] = rejection.reason;
            result["settled_day"] = index;
            publish_boundary_command_result(rejection.command, rejection.caller_sequence, std::move(result));
        }
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

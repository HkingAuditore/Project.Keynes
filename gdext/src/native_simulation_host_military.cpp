#include "native_simulation_day_context.h"
#include "native_military_runtime.h"
#include "economy_api.h"
#include "runtime_vision.h"
#include "world_ext.h"

#include <algorithm>
#include <atomic>
#include <cstring>
#include <utility>

namespace pk {

void NativeMilitaryRuntime::publish(godot::Dictionary report) {
    auto frame = std::make_shared<Published>();
    frame->view = std::make_shared<MilitaryCore>(core);
    frame->archive = encode();
    frame->state_hash = static_cast<int64_t>(core.state_hash() & 0x7fffffffffffffffll);
    frame->last_step_day = _military_last_step_day;
    frame->executor_day = _military_last_background_day;
    frame->sequence = _military_sequence;
    frame->pending_intents = static_cast<int64_t>(_military_pending_intents.size());
    frame->revision = _military_render_revision;
    frame->event_cursor = event_cursor;
    frame->event_tick = event_tick;
    frame->events_forwarded = events_forwarded;
    if (_economy_runtime != nullptr) {
        frame->lane_supported = true;
        frame->lane_pay_supported = economy_api::military_army_lane_pay_supported(*_economy_runtime);
        const auto &armies = core.armies();
        frame->lane_population.assign(armies.active.size(), -1);
        frame->lane_funds.assign(armies.active.size(), -1);
        for (size_t index = 0; index < armies.active.size(); ++index) {
            if (!armies.active[index]) continue;
            const auto handle = core.army_handle(static_cast<int32_t>(index));
            frame->lane_population[index] = economy_api::military_army_population(*_economy_runtime, handle);
            frame->lane_funds[index] = economy_api::military_army_funds(*_economy_runtime, handle);
        }
    }
    frame->result = std::move(report);
    std::atomic_store_explicit(&_published, std::shared_ptr<const Published>(std::move(frame)),
        std::memory_order_release);
}

std::shared_ptr<const NativeMilitaryRuntime::Published> NativeMilitaryRuntime::read() const {
    return std::atomic_load_explicit(&_published, std::memory_order_acquire);
}

bool NativeMilitaryRuntime::forward_events(int64_t day, DCWorldExt *legacy) {
    for (;;) {
        const auto events = core.events_after(static_cast<uint64_t>(event_cursor), 256u);
        if (events.empty()) return true;
        for (size_t begin = 0; begin < events.size(); begin += RUNTIME_EVENTS_MAX_BATCH_RECORDS) {
            const size_t end = std::min(events.size(), begin + RUNTIME_EVENTS_MAX_BATCH_RECORDS);
            std::vector<RuntimeEventsRecord> records;
            records.reserve(end - begin);
            for (size_t i = begin; i < end; ++i) {
                const auto &event = events[i];
                auto &record = records.emplace_back();
                if (!legacy) record.event_id = _runtime_host->allocate_events_ingress_key();
                record.tick = event_tick;
                record.type = std::clamp<int32_t>(event.type, 40, 47);
                record.source = 5;
                record.entity_id = static_cast<int32_t>(event.i0);
                record.entity_handle = event.i0;
                record.cell_idx = event.cell;
                record.payload_schema = event.payload_schema;
                record.value_i64 = event.value;
                record.payload_i0 = static_cast<int32_t>(event.i0);
                record.payload_i1 = static_cast<int32_t>(event.i1);
                record.payload_i2 = static_cast<int32_t>(event.i2);
                record.payload_i3 = static_cast<int32_t>(event.i3);
            }
            if (legacy) {
                if (!legacy->publish_legacy_military_events(records)) return false;
            } else {
                std::string error;
                if (!_runtime_host->enqueue_legacy_event_batch(
                        records, day + 1, _runtime_host->report().generation + 1, error))
                    return false;
            }
            events_forwarded += static_cast<int64_t>(records.size());
            event_cursor = static_cast<int64_t>(events[end - 1].id);
        }
    }
}

const char *NativeMilitaryRuntime::prepare_day(const RuntimeEnvironmentSnapshot &environment) {
    // Military terrain changes at the seasonal refresh boundary. Daily weather
    // also changes cover, but those changes never refreshed military costs.
    if (!environment.climate_season_refresh_ran) return nullptr;
    const size_t count = static_cast<size_t>(core.terrain().cell_count);
    if (environment.cover.size() != count) return "military_terrain_cover_shape_invalid";
    if (environment.cover != core.terrain().cover) {
        auto terrain = core.terrain();
        terrain.cover = environment.cover;
        terrain.vegetation = environment.vegetation;
        if (!environment.military_base_landform.empty())
            terrain.landform = environment.military_base_landform;
        if (!environment.military_settlement_tier.empty())
            terrain.settlement_tier = environment.military_settlement_tier;

        const auto wire = encode();
        godot::PackedByteArray saved;
        saved.resize(static_cast<int64_t>(wire.size()));
        std::memcpy(saved.ptrw(), wire.data(), wire.size());
        std::string error;
        if (!core.set_terrain(std::move(terrain), error) ||
            !static_cast<bool>(restore(saved).get("ok", false)))
            return "military_season_terrain_restore_failed";
    }
    return nullptr;
}

void NativeSimulationHost::attach_military(std::shared_ptr<NativeMilitaryRuntime> military) {
    _executor_military = std::move(military);
    if (_executor_military) {
        _executor_military->_runtime_host = this;
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
    if (_executor_vision && _executor_vision->player_slot >= 0 && military.core.has_exploration_work()) {
        const auto &vision = *_executor_vision->frame;
        military.core.set_exploration_view(_executor_vision->player_slot, vision.explored.data(),
            vision.explored.size(), index, vision.revision);
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

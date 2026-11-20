#include "native_simulation_day_context.h"
#include "pk_log.h"
#include "runtime_world_environment.h"

#include <algorithm>

namespace pk {

bool NativeSimulationHost::initialize_world_environment(RuntimeEnvironmentSnapshot &&seed,
        const godot::Dictionary &config, std::string &error) {
    if (!execution_has_stopped()) {
        error = "runtime_environment_requires_stopped_executor";
        return false;
    }
    if (!validate_runtime_environment_snapshot(seed, error)) return false;
    const godot::PackedByteArray water = config.get("water_lut", godot::PackedByteArray());
    if (water.size() != 256 || seed.climate_capture_cursors.size() != 11 ||
        seed.climate_round_input.radiative_modifier_add.size() != seed.cell_count ||
        seed.climate_round_input.radiative_modifier_factor.size() != seed.cell_count ||
        seed.is_water.size() != seed.cell_count || seed.landform.size() != seed.cell_count ||
        seed.military_base_landform.size() != seed.cell_count) {
        error = "runtime_environment_seed_shape_invalid";
        return false;
    }
    _world_environment = std::make_shared<RuntimeWorldEnvironment>(std::move(seed), config);
    if (_has_pending_restore &&
            (_pending_restore_bundle.section_mask & RUNTIME_SAVE_SECTION_SEASON_HISTORY) != 0 &&
            !_world_environment->restore_season_history(_pending_restore_bundle.season_history_bytes,
                _pending_restore_bundle.committed_day))
        log_error("season history restore: runtime_bundle_season_history_invalid");
    _clock_requested_day.store(-1, std::memory_order_release);
    return true;
}

int64_t NativeSimulationHost::request_runtime_calendar_day(int64_t date) {
    if (!_world_environment) return -1;
    std::lock_guard<std::mutex> lock(_control_mutex);
    const int64_t committed = committed_day_value();
    const int64_t displayed = _display_consumed_day.load(std::memory_order_acquire);
    const int64_t lead = _speed_days_per_second.load(std::memory_order_acquire) <= 1.0
        ? 1 : CALENDAR_LOOKAHEAD;
    const int64_t ceiling = std::max(committed, std::min(committed + lead,
        displayed + CALENDAR_LOOKAHEAD));
    const int64_t requested = std::max<int64_t>(0, date) - 1;
    const int64_t through = std::clamp(std::max(requested, _clock_requested_day.load(
        std::memory_order_relaxed)), committed, ceiling);
    _clock_requested_day.store(through, std::memory_order_release);
    _calendar_suspended.store(false, std::memory_order_release);
    _control_cv.notify_all();
    return through;
}

std::unique_lock<std::mutex> NativeSimulationHost::try_lock_economy_read_boundary() const {
    // The foreground admits days on the same thread as these compatibility
    // reads. Once it admits a day, use the published view until it settles.
    if (_world_environment && !_calendar_suspended.load(std::memory_order_acquire) &&
        _clock_requested_day.load(std::memory_order_acquire) >
            _committed_day.load(std::memory_order_acquire)) return {};
    return std::unique_lock<std::mutex>(_economy_authority_boundary_mutex, std::try_to_lock);
}

std::shared_ptr<const RuntimeEnvironmentSnapshot>
NativeSimulationHost::executor_environment_for_day(int64_t day) {
    const auto submitted = environment_input_for_plan();
    if (!_world_environment || (submitted && submitted->day == day))
        return submitted;
    const char *error = nullptr;
    const auto generation = std::max(_environment_generation.load(std::memory_order_acquire),
        _climate_authority.last_input_generation()) + 1;
    auto input = _world_environment->prepare(day, generation, _climate_authority,
        _economy_modifier_view, _economy_production_runtime, annual_development_enabled(), error);
    if (!input) {
        set_fault(error ? error : "runtime_executor_environment_unavailable");
        return {};
    }
    std::atomic_store_explicit(&_environment_snapshot, input, std::memory_order_release);
    _environment_published_days.fetch_add(1, std::memory_order_relaxed);
    _environment_generation.store(input->generation, std::memory_order_release);
    _environment_day.store(input->day, std::memory_order_release);
    _environment_cell_count.store(input->cell_count, std::memory_order_release);
    _environment_topology_validated.store(input->topology_validated, std::memory_order_release);
    return input;
}

const char *NativeSimulationHost::stage_prepare_environment(DayExecution &day) {
    if (!_world_environment) return nullptr;
    const char *error = nullptr;
    _world_environment->prepare(day.plan.context.day + 1, day.plan.context.input_generation + 1,
        _climate_authority, _economy_modifier_view, _economy_production_runtime,
        annual_development_enabled(), error);
    return error;
}

void NativeSimulationHost::capture_climate_display(RuntimeClimateSnapshot &out) const {
    _climate_authority.snapshot_into(out, true);
    out.season = _world_environment ? _world_environment->season_view(out.committed_day) : nullptr;
    out.calendar = _world_environment ?
        std::make_shared<RuntimeClimateCalendar>(_world_environment->calendar(out.committed_day)) : nullptr;
}

} // namespace pk

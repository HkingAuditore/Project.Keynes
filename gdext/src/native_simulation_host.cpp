#include "native_simulation_host.h"
#include "native_parallel_executor.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <cmath>
#include <limits>

#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif

namespace pk {

NativeSimulationHost::NativeSimulationHost() {
    _pod_visual_intents.reserve(RUNTIME_DOMAIN_INTENT_CAPACITY);
    _pod_receipts.reserve(RUNTIME_RECEIPT_QUEUE_CAPACITY);
    for (auto &sequence : _producer_sequences) {
        sequence.store(0, std::memory_order_relaxed);
    }
    for (uint64_t i = 0; i < RUNTIME_COMMAND_QUEUE_CAPACITY; ++i) {
        _command_slots[i].sequence.store(i, std::memory_order_relaxed);
    }
    for (auto &generation : _dirty_family_generations) {
        generation.store(0, std::memory_order_relaxed);
    }
    for (auto &character : _fault_code) character.store('\0', std::memory_order_relaxed);
    for (auto &character : _domain_authority_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
}

NativeSimulationHost::~NativeSimulationHost() {
    request_stop();
    join_for_destruction();
}

bool NativeSimulationHost::reap_completed_worker_nonblocking() {
    if (!_worker.joinable()) return true;

    // Do not move a joinable std::thread into a lambda capture directly: if
    // the std::thread constructor throws, destruction of that capture would
    // call std::terminate. A shared holder lets the failure path move the
    // handle back into this object without blocking the caller.
    auto holder = std::make_shared<std::thread>(std::move(_worker));
    _reaper_count.fetch_add(1, std::memory_order_acq_rel);
    try {
        std::thread([this, holder]() {
            if (holder->joinable()) holder->join();
            if (_reaper_count.fetch_sub(1, std::memory_order_acq_rel) == 1) {
                std::lock_guard<std::mutex> lock(_control_mutex);
                _control_cv.notify_all();
            }
        }).detach();
    } catch (...) {
        _worker = std::move(*holder);
        _reaper_count.fetch_sub(1, std::memory_order_acq_rel);
        return false;
    }
    return true;
}

uint64_t NativeSimulationHost::now_us() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

uint64_t NativeSimulationHost::mix_hash(uint64_t value, uint64_t input) {
    value ^= input + 0x9e3779b97f4a7c15ull + (value << 6) + (value >> 2);
    value *= 1099511628211ull;
    return value;
}

bool NativeSimulationHost::start(RuntimeSimulationMode mode,
                                  bool graph_coverage_complete,
                                  int64_t initial_day,
                                  double speed_days_per_second,
                                  bool paused) {
    RuntimeWorkerState expected = RuntimeWorkerState::STOPPED;
    if (!_state.compare_exchange_strong(expected, RuntimeWorkerState::STARTING,
            std::memory_order_acq_rel, std::memory_order_relaxed)) {
        return false;
    }
    // A std::thread remains joinable after worker_main publishes STOPPED. Hand
    // that completed handle to a detached reaper instead of making the Godot
    // caller wait in join(). The host remains alive until destruction waits for
    // all reapers, and the old worker performs no access after publishing
    // STOPPED.
    if (!reap_completed_worker_nonblocking()) {
        _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
        return false;
    }
    if (mode == RuntimeSimulationMode::OFF) {
        _mode.store(RuntimeSimulationMode::OFF, std::memory_order_release);
        _graph_coverage_complete.store(false, std::memory_order_release);
        _authority_ready.store(false, std::memory_order_release);
        _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
        return true;
    }
    if (mode == RuntimeSimulationMode::ACTIVE &&
        (!graph_coverage_complete ||
         implemented_domain_mask() != RUNTIME_ALL_DOMAIN_MASK)) {
        _mode.store(RuntimeSimulationMode::OFF, std::memory_order_release);
        _graph_coverage_complete.store(false, std::memory_order_release);
        _authority_ready.store(false, std::memory_order_release);
        const char *blocker = graph_coverage_complete &&
            implemented_domain_mask() != RUNTIME_ALL_DOMAIN_MASK
            ? "missing_native_domain_handlers"
            : "runtime_graph_not_thread_safe";
        size_t i = 0;
        for (; i + 1 < _fault_code.size() && blocker[i] != '\0'; ++i) {
            _fault_code[i].store(blocker[i], std::memory_order_relaxed);
        }
        for (; i < _fault_code.size(); ++i) {
            _fault_code[i].store('\0', std::memory_order_relaxed);
        }
        _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
        return false;
    }
    const bool restore_pending = _has_pending_restore;
    const int64_t start_day = restore_pending
        ? _pending_restore_bundle.committed_day : initial_day;
    const double start_speed = restore_pending
        ? _pending_restore_bundle.speed_days_per_second : speed_days_per_second;
    const bool start_paused = restore_pending
        ? _pending_restore_bundle.paused : paused;
    const uint64_t start_generation = restore_pending
        ? _pending_restore_bundle.generation : 0;
    const uint64_t start_state_hash = restore_pending
        ? _pending_restore_bundle.state_hash : 1469598103934665603ull;
    const double start_time_debt = restore_pending
        ? _pending_restore_bundle.time_debt_days : 0.0;
    const uint64_t restored_environment_generation = restore_pending
        ? _pending_restore_bundle.environment_generation : 0;
    const int64_t restored_environment_day = restore_pending
        ? _pending_restore_bundle.environment_day : start_day;
    if (restore_pending) {
        _worker_initial_pending_commands =
            std::move(_pending_restore_bundle.pending_commands);
    } else {
        _worker_initial_pending_commands.clear();
    }
    // The caller's flag is only an eligibility request.  Coverage is proven
    // by the worker after a complete RuntimeDayPlan barrier; accepting an
    // external `true` here must never make the facade report ACTIVE.
    _graph_coverage_complete.store(false, std::memory_order_release);
    _authority_ready.store(false, std::memory_order_release);
    _mode.store(mode, std::memory_order_release);
    _committed_day.store(start_day, std::memory_order_release);
    _speed_days_per_second.store(std::max(0.0, start_speed),
                                 std::memory_order_release);
    _paused.store(start_paused, std::memory_order_release);
    _stop_requested.store(false, std::memory_order_release);
    _generation.store(start_generation, std::memory_order_release);
    _latest_from_day.store(start_day, std::memory_order_release);
    _latest_committed_day.store(start_day, std::memory_order_release);
    _latest_produced_at_us.store(0, std::memory_order_release);
    _latest_dirty_families.store(0, std::memory_order_release);
    _latest_receipt_count.store(0, std::memory_order_release);
    _last_visual_publish_us.store(0, std::memory_order_release);
    _snapshot_publish_throttled_count.store(0, std::memory_order_release);
    _last_commit_produced_at_us.store(0, std::memory_order_release);
    for (auto &family_generation : _dirty_family_generations) {
        family_generation.store(0, std::memory_order_release);
    }
    _ui_input_to_feedback_ms.store(0.0, std::memory_order_release);
    _visual_apply_ms.store(0.0, std::memory_order_release);
    _gpu_upload_ms.store(0.0, std::memory_order_release);
    _completed_days.store(0, std::memory_order_release);
    _last_day_stage_count.store(0, std::memory_order_release);
    _last_day_completed_stages.store(0, std::memory_order_release);
    _last_day_work_units.store(0, std::memory_order_release);
    _pod_completed_domain_mask.store(0, std::memory_order_release);
    _pod_completed_stage_count.store(0, std::memory_order_release);
    _pod_work_units.store(0, std::memory_order_release);
    _pod_intent_count.store(0, std::memory_order_release);
    _pod_fallback_count.store(0, std::memory_order_release);
    _domain_authority_planned_mask.store(0, std::memory_order_release);
    _domain_authority_committed_mask.store(0, std::memory_order_release);
    _domain_authority_ack_count.store(0, std::memory_order_release);
    _domain_authority_input_hash.store(0, std::memory_order_release);
    _domain_authority_state_hash.store(0, std::memory_order_release);
    _domain_authority_plan_ms.store(0.0, std::memory_order_release);
    _domain_authority_replay_ms.store(0.0, std::memory_order_release);
    for (auto &character : _domain_authority_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    _domain_stage_fallback_count.store(0, std::memory_order_release);
    for (auto &character : _domain_stage_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    _climate_pod_ready.store(false, std::memory_order_release);
    _climate_pod_plan_ms.store(0.0, std::memory_order_release);
    _climate_pod_replay_ms.store(0.0, std::memory_order_release);
    _climate_pod_work_units.store(0, std::memory_order_release);
    _climate_pod_changed_cells.store(0, std::memory_order_release);
    _climate_pod_state_hash.store(0, std::memory_order_release);
    _climate_pod_reference_hash.store(0, std::memory_order_release);
    _climate_pod_parity_compared.store(false, std::memory_order_release);
    _climate_pod_parity_matched.store(false, std::memory_order_release);
    _climate_pod_parity_mismatch_count.store(0, std::memory_order_release);
    for (auto &character : _climate_pod_parity_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    _climate_parity_day.store(-1, std::memory_order_release);
    _climate_parity_stage.store(0, std::memory_order_release);
    _climate_parity_cell.store(0, std::memory_order_release);
    _climate_parity_input_generation.store(0, std::memory_order_release);
    _climate_parity_base_generation.store(0, std::memory_order_release);
    _climate_parity_trace_hash.store(0, std::memory_order_release);
    for (auto &character : _climate_parity_field) character.store('\0', std::memory_order_relaxed);
    for (auto &character : _climate_parity_reference_bits) character.store('\0', std::memory_order_relaxed);
    for (auto &character : _climate_parity_worker_bits) character.store('\0', std::memory_order_relaxed);
    for (auto &character : _climate_pod_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    _time_debt_days.store(std::clamp(start_time_debt, 0.0, 100.0),
                          std::memory_order_release);
    const auto existing_environment = environment_snapshot();
    if (existing_environment != nullptr) {
        _environment_generation.store(existing_environment->generation, std::memory_order_release);
        _environment_day.store(existing_environment->day, std::memory_order_release);
        _environment_cell_count.store(existing_environment->cell_count,
                                      std::memory_order_release);
        _environment_topology_validated.store(existing_environment->topology_validated,
                                              std::memory_order_release);
    } else {
        _environment_generation.store(0, std::memory_order_release);
        _environment_day.store(restored_environment_day, std::memory_order_release);
        _environment_cell_count.store(0, std::memory_order_release);
        _environment_topology_validated.store(false, std::memory_order_release);
    }
    if (restored_environment_generation >
            _environment_generation.load(std::memory_order_acquire)) {
        _environment_generation.store(restored_environment_generation,
                                      std::memory_order_release);
        _environment_day.store(restored_environment_day,
                               std::memory_order_release);
    }
    _command_enqueue_pos.store(0, std::memory_order_relaxed);
    _command_dequeue_pos.store(0, std::memory_order_relaxed);
    for (uint64_t i = 0; i < RUNTIME_COMMAND_QUEUE_CAPACITY; ++i) {
        _command_slots[i].sequence.store(i, std::memory_order_relaxed);
    }
    _receipt_write.store(0, std::memory_order_relaxed);
    _receipt_read.store(0, std::memory_order_relaxed);
    for (size_t i = 0; i < _producer_sequences.size(); ++i) {
        const uint64_t restored_sequence = restore_pending
            ? _pending_restore_bundle.producer_sequences[i] : 0;
        _producer_sequences[i].store(restored_sequence,
                                     std::memory_order_relaxed);
    }
    _fallback_producer_sequence.store(restore_pending
            ? _pending_restore_bundle.fallback_producer_sequence : 0,
        std::memory_order_relaxed);
    _save_requested.store(false, std::memory_order_release);
    _save_request_id.store(0, std::memory_order_release);
    _save_consumed_request_id.store(0, std::memory_order_release);
    std::atomic_store_explicit(&_save_bundle,
        std::shared_ptr<const RuntimeSaveBundle>(), std::memory_order_release);
    _snapshots.reset();
    // WorldRuntimeHost captures the initial immutable input immediately
    // before starting the worker. Preserve that frame so the OFF reference
    // can release it after the synchronous day boundary. A trace belonging to
    // another start/day is discarded explicitly.
    int64_t trace_front_day = -1;
    if (_climate_trace.front_day(trace_front_day) && trace_front_day != start_day) {
        _climate_trace.reset();
    }
    _climate_trace_consumed.store(0, std::memory_order_release);
    _climate_trace_missing.store(0, std::memory_order_release);
    _climate_trace_latest_hash.store(0, std::memory_order_release);
    _climate_trace_signal.store(0, std::memory_order_release);
    _state_hash.store(start_state_hash, std::memory_order_release);
    const auto bootstrap_environment = environment_snapshot();
    const auto bootstrap_country = std::atomic_load_explicit(
        &_country_snapshot, std::memory_order_acquire);
    _pod_pipeline.reset(
        bootstrap_environment != nullptr ? bootstrap_environment->cell_count : 0u,
        bootstrap_country != nullptr ? bootstrap_country->country_count : 0u);
    _authoritative_domains.reset(
        bootstrap_environment != nullptr ? bootstrap_environment->cell_count : 0u,
        bootstrap_country != nullptr ? bootstrap_country->country_count : 0u);
    _domain_authority_runner.reset(
        bootstrap_environment != nullptr ? bootstrap_environment->cell_count : 0u,
        bootstrap_country != nullptr ? bootstrap_country->country_count : 0u);
    _climate_authority.reset(
        bootstrap_environment != nullptr ? bootstrap_environment->cell_count : 0u);
    if (restore_pending && !_pending_restore_bundle.domain_pod_bytes.empty()) {
        std::string pod_restore_error;
        if (!_pod_pipeline.restore(_pending_restore_bundle.domain_pod_bytes.data(),
                                   _pending_restore_bundle.domain_pod_bytes.size(),
                                   pod_restore_error)) {
            set_fault(pod_restore_error.c_str());
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
    }
    if (restore_pending && !_pending_restore_bundle.climate_bytes.empty()) {
        std::string climate_restore_error;
        if (!_climate_authority.restore(_pending_restore_bundle.climate_bytes.data(),
                                        _pending_restore_bundle.climate_bytes.size(),
                                        climate_restore_error)) {
            set_fault(climate_restore_error.empty() ? "climate_restore_failed" :
                      climate_restore_error.c_str());
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
            return false;
        }
    }
    _pod_visual_intents.clear();
    _pod_receipts.clear();
    _has_pending_restore = false;
    _pending_restore_bundle = RuntimeSaveBundle{};
    for (auto &character : _fault_code) character.store('\0', std::memory_order_relaxed);
    try {
        _worker = std::thread(&NativeSimulationHost::worker_main, this);
    } catch (...) {
        // A failed thread creation must leave the host reusable.  Returning
        // false while keeping STARTING would make every later start look like
        // a forbidden hot switch and would strand the caller without a
        // lifecycle completion signal.
        _worker_fault_count.fetch_add(1, std::memory_order_relaxed);
        const char *fault = "worker_thread_create_failed";
        size_t fault_size = 0;
        for (; fault_size + 1 < _fault_code.size() && fault[fault_size] != '\0';
             ++fault_size) {
            _fault_code[fault_size].store(fault[fault_size],
                                          std::memory_order_relaxed);
        }
        for (; fault_size < _fault_code.size(); ++fault_size)
            _fault_code[fault_size].store('\0', std::memory_order_relaxed);
        _stop_requested.store(true, std::memory_order_release);
        _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
        return false;
    }
    return true;
}

void NativeSimulationHost::request_stop() {
    const RuntimeWorkerState current = _state.load(std::memory_order_acquire);
    if (current == RuntimeWorkerState::STOPPED) return;
    _stop_requested.store(true, std::memory_order_release);
    if (current != RuntimeWorkerState::FAULTED) {
        _state.store(RuntimeWorkerState::STOPPING, std::memory_order_release);
    }
    _control_cv.notify_all();
}

void NativeSimulationHost::join_for_destruction() {
    if (_worker.joinable()) _worker.join();
    if (_reaper_count.load(std::memory_order_acquire) != 0) {
        std::unique_lock<std::mutex> lock(_control_mutex);
        _control_cv.wait(lock, [this]() {
            return _reaper_count.load(std::memory_order_acquire) == 0;
        });
    }
    _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
}

void NativeSimulationHost::set_clock(bool paused, double speed_days_per_second) {
    _paused.store(paused, std::memory_order_release);
    _speed_days_per_second.store(std::max(0.0, speed_days_per_second),
                                 std::memory_order_release);
    _control_cv.notify_all();
}

void NativeSimulationHost::set_interactive(bool interactive) {
    _interactive.store(interactive, std::memory_order_release);
    _control_cv.notify_all();
}

void NativeSimulationHost::record_visual_timings(
        double ui_input_to_feedback_ms,
        double visual_apply_ms,
        double gpu_upload_ms) {
    // Clamp and ignore NaN/Inf at the boundary so a broken renderer probe can
    // never poison the diagnostic stream or make a CSV parser fail.
    const auto sanitize = [](double value) {
        return std::isfinite(value) ? std::max(0.0, value) : 0.0;
    };
    _ui_input_to_feedback_ms.store(sanitize(ui_input_to_feedback_ms),
                                   std::memory_order_release);
    _visual_apply_ms.store(sanitize(visual_apply_ms), std::memory_order_release);
    _gpu_upload_ms.store(sanitize(gpu_upload_ms), std::memory_order_release);
}

bool NativeSimulationHost::publish_environment(
        const RuntimeEnvironmentSnapshot &snapshot, std::string &error) {
    error.clear();
    std::string validation_error;
    if (!validate_runtime_environment_snapshot(snapshot, validation_error)) {
        _invalid_environment_rejected.fetch_add(1, std::memory_order_relaxed);
        error = validation_error;
        return false;
    }
    const auto previous = environment_snapshot();
    // Generation is the immutable publication sequence, not merely a day
    // label. Rejecting equality as well as rollback prevents duplicate trace
    // frames after restore or a repeated capture at the same day.
    if (previous != nullptr && snapshot.generation <= previous->generation) {
        _stale_environment_rejected.fetch_add(1, std::memory_order_relaxed);
        error = "runtime_input_stale";
        return false;
    }
    if (snapshot.day < _committed_day.load(std::memory_order_acquire)) {
        _stale_environment_rejected.fetch_add(1, std::memory_order_relaxed);
        error = "runtime_input_before_committed_day";
        return false;
    }
    // The trace is the replay boundary, not a best-effort diagnostic side
    // channel. Reject the capture before publishing the live convenience
    // snapshot when its bounded storage is full; this preserves the invariant
    // that every accepted input has a corresponding OFF reference release.
    if (!_climate_trace.push(snapshot)) {
        error = "climate_trace_capacity_exceeded";
        return false;
    }
    auto copy = std::make_shared<RuntimeEnvironmentSnapshot>(snapshot);
    std::atomic_store_explicit(&_environment_snapshot,
        std::shared_ptr<const RuntimeEnvironmentSnapshot>(std::move(copy)),
        std::memory_order_release);
    _environment_generation.store(snapshot.generation, std::memory_order_release);
    _environment_day.store(snapshot.day, std::memory_order_release);
    _environment_cell_count.store(snapshot.cell_count, std::memory_order_release);
    _environment_topology_validated.store(snapshot.topology_validated,
                                           std::memory_order_release);
    return true;
}

bool NativeSimulationHost::publish_climate_reference(
        int64_t day, uint64_t reference_state_hash,
        std::string &error) {
    if (day < 0 || reference_state_hash == 0) {
        error = "climate_trace_reference_invalid";
        return false;
    }
    uint64_t input_hash = 0;
    if (!_climate_trace.input_hash_for_day(day, input_hash)) {
        error = "climate_trace_reference_frame_missing";
        return false;
    }
    if (!_climate_trace.mark_reference_ready(
            day, input_hash, reference_state_hash, error)) {
        return false;
    }
    const bool ready = _climate_trace.mark_consumable(day, error);
    if (ready) {
        _climate_trace_signal.fetch_add(1, std::memory_order_acq_rel);
        _control_cv.notify_all();
    }
    return ready;
}

bool NativeSimulationHost::publish_country_snapshot(
        const RuntimeCountryPodSnapshot &snapshot) {
    std::string error;
    if (!RuntimeCountryPodAdapter::validate_snapshot(snapshot, error)) return false;
    auto copy = std::make_shared<RuntimeCountryPodSnapshot>(snapshot);
    std::atomic_store_explicit(&_country_snapshot,
        std::shared_ptr<const RuntimeCountryPodSnapshot>(std::move(copy)),
        std::memory_order_release);
    return true;
}

RuntimeCountryPodDiagnostics NativeSimulationHost::country_pod_diagnostics() const {
    const auto value = std::atomic_load_explicit(&_country_pod_diagnostics,
        std::memory_order_acquire);
    return value != nullptr ? *value : RuntimeCountryPodDiagnostics{};
}

std::shared_ptr<const RuntimeEnvironmentSnapshot>
NativeSimulationHost::environment_snapshot() const {
    return std::atomic_load_explicit(&_environment_snapshot, std::memory_order_acquire);
}

bool NativeSimulationHost::enqueue(RuntimeCommandPacket packet) {
    const RuntimeWorkerState current = _state.load(std::memory_order_acquire);
    if (current == RuntimeWorkerState::STOPPED ||
        current == RuntimeWorkerState::STOPPING ||
        current == RuntimeWorkerState::FAULTED) return false;
    uint64_t position = _command_enqueue_pos.load(std::memory_order_relaxed);
    CommandQueueSlot *slot = nullptr;
    for (;;) {
        slot = &_command_slots[position % RUNTIME_COMMAND_QUEUE_CAPACITY];
        const uint64_t sequence = slot->sequence.load(std::memory_order_acquire);
        const int64_t difference = static_cast<int64_t>(sequence - position);
        if (difference == 0) {
            if (_command_enqueue_pos.compare_exchange_weak(
                    position, position + 1, std::memory_order_relaxed,
                    std::memory_order_relaxed)) {
                break;
            }
        } else if (difference < 0) {
            _command_queue_capacity_exceeded.fetch_add(1, std::memory_order_relaxed);
            return false;
        } else {
            position = _command_enqueue_pos.load(std::memory_order_relaxed);
        }
    }
    slot->packet = packet;
    slot->sequence.store(position + 1, std::memory_order_release);
    _control_cv.notify_one();
    return true;
}

uint64_t NativeSimulationHost::allocate_producer_sequence(uint32_t producer_id) {
    if (producer_id < _producer_sequences.size()) {
        return _producer_sequences[producer_id].fetch_add(1, std::memory_order_relaxed) + 1;
    }
    return _fallback_producer_sequence.fetch_add(1, std::memory_order_relaxed) + 1;
}

bool NativeSimulationHost::pop_command(RuntimeCommandPacket &out) {
    uint64_t position = _command_dequeue_pos.load(std::memory_order_relaxed);
    CommandQueueSlot *slot = nullptr;
    for (;;) {
        slot = &_command_slots[position % RUNTIME_COMMAND_QUEUE_CAPACITY];
        const uint64_t sequence = slot->sequence.load(std::memory_order_acquire);
        const int64_t difference = static_cast<int64_t>(sequence - (position + 1));
        if (difference == 0) {
            if (_command_dequeue_pos.compare_exchange_weak(
                    position, position + 1, std::memory_order_relaxed,
                    std::memory_order_relaxed)) {
                break;
            }
        } else if (difference < 0) {
            return false;
        } else {
            position = _command_dequeue_pos.load(std::memory_order_relaxed);
        }
    }
    out = slot->packet;
    slot->sequence.store(position + RUNTIME_COMMAND_QUEUE_CAPACITY,
                         std::memory_order_release);
    return true;
}

bool NativeSimulationHost::next_command(RuntimeCommandPacket &out) const {
    const uint64_t position = _command_dequeue_pos.load(std::memory_order_relaxed);
    const CommandQueueSlot &slot = _command_slots[position % RUNTIME_COMMAND_QUEUE_CAPACITY];
    const uint64_t sequence = slot.sequence.load(std::memory_order_acquire);
    if (sequence != position + 1) return false;
    out = slot.packet;
    return true;
}

bool NativeSimulationHost::push_receipt(const RuntimeCommandReceipt &receipt) {
    const uint64_t write = _receipt_write.load(std::memory_order_relaxed);
    const uint64_t read = _receipt_read.load(std::memory_order_acquire);
    if (write - read >= RUNTIME_RECEIPT_QUEUE_CAPACITY) {
        _receipt_queue_capacity_exceeded.fetch_add(1, std::memory_order_relaxed);
        return false;
    }
    _receipts[write % RUNTIME_RECEIPT_QUEUE_CAPACITY] = receipt;
    _receipt_write.store(write + 1, std::memory_order_release);
    return true;
}

bool NativeSimulationHost::poll_receipt(RuntimeCommandReceipt &out) {
    const uint64_t read = _receipt_read.load(std::memory_order_relaxed);
    const uint64_t write = _receipt_write.load(std::memory_order_acquire);
    if (read == write) return false;
    out = _receipts[read % RUNTIME_RECEIPT_QUEUE_CAPACITY];
    _receipt_read.store(read + 1, std::memory_order_release);
    return true;
}

bool NativeSimulationHost::poll_commit(uint64_t after_generation, RuntimeCommit &out) {
    const uint64_t latest_generation = _generation.load(std::memory_order_acquire);
    uint32_t index = 0;
    if (_snapshots.try_acquire_latest(after_generation, index)) {
        RuntimeCommit candidate = _snapshots.read_buffer(index);
        _snapshots.release(index);
        // Visual publication is intentionally throttled.  A READY buffer may
        // therefore describe an older generation than the authoritative scalar
        // header. Never move the facade backwards just because the newest
        // visual buffer is still within the 20 Hz window; return the scalar
        // boundary below and let visual patch consumption remain generation
        // aware.
        if (candidate.header.generation >= latest_generation) {
            out = std::move(candidate);
            return true;
        }
    }
    // The visual ring is allowed to drop intents under backpressure, but a
    // dropped buffer must not erase the authoritative commit boundary.
    const uint64_t generation = _generation.load(std::memory_order_acquire);
    // A throttled visual publication still advances the authoritative
    // generation. Return the scalar header even when no READY buffer exists;
    // the caller can then observe progress while visual patch consumption
    // remains generation-aware and may legitimately report no intents.
    if (generation == 0 || generation <= after_generation) return false;
    out = RuntimeCommit{};
    out.header.generation = generation;
    out.header.from_day = _latest_from_day.load(std::memory_order_acquire);
    out.header.committed_day = _latest_committed_day.load(std::memory_order_acquire);
    out.header.produced_at_us = _latest_produced_at_us.load(std::memory_order_acquire);
    out.header.dirty_families = _latest_dirty_families.load(std::memory_order_acquire);
    out.header.state_hash = _state_hash.load(std::memory_order_acquire);
    out.header.command_receipt_count = _latest_receipt_count.load(std::memory_order_acquire);
    for (size_t family_index = 0; family_index < RUNTIME_DIRTY_FAMILY_COUNT; ++family_index) {
        out.header.dirty_family_generations[family_index] =
            _dirty_family_generations[family_index].load(std::memory_order_acquire);
    }
    return true;
}

bool NativeSimulationHost::poll_commit_generation(uint64_t generation, RuntimeCommit &out) {
    uint32_t index = 0;
    if (_snapshots.try_acquire_generation(generation, index)) {
        out = _snapshots.read_buffer(index);
        _snapshots.release(index);
        return true;
    }
    // Exact lookup is only reconstructible for the newest scalar header. A
    // throttled generation has no visual buffer, but the current generation
    // is still a valid authoritative commit boundary.
    if (generation == 0 ||
        generation != _generation.load(std::memory_order_acquire)) return false;
    out = RuntimeCommit{};
    out.header.generation = generation;
    out.header.from_day = _latest_from_day.load(std::memory_order_acquire);
    out.header.committed_day = _latest_committed_day.load(std::memory_order_acquire);
    out.header.produced_at_us = _latest_produced_at_us.load(std::memory_order_acquire);
    out.header.dirty_families = _latest_dirty_families.load(std::memory_order_acquire);
    out.header.state_hash = _state_hash.load(std::memory_order_acquire);
    out.header.command_receipt_count = _latest_receipt_count.load(std::memory_order_acquire);
    for (size_t family_index = 0; family_index < RUNTIME_DIRTY_FAMILY_COUNT; ++family_index) {
        out.header.dirty_family_generations[family_index] =
            _dirty_family_generations[family_index].load(std::memory_order_acquire);
    }
    return true;
}

RuntimeDayPlan NativeSimulationHost::build_day_plan(
        int64_t day, double speed_scale,
        const RuntimeEnvironmentSnapshot *environment) const {
    RuntimeDayPlan plan;
    plan.context.day = day;
    plan.context.season_phase = environment != nullptr
        ? environment->season_phase : 0.0;
    plan.context.speed_scale = speed_scale;
    plan.context.input_generation = environment != nullptr
        ? environment->generation : 0;
    plan.context.environment = environment;

    constexpr auto order = runtime_domain_stage_order();
    for (uint32_t i = 0; i < plan.stage_count; ++i)
        plan.stages[i].domain = order[i];
    return plan;
}

RuntimeDayCommit NativeSimulationHost::execute_day_plan(
        RuntimeDayPlan &plan) {
    RuntimeDayCommit commit;
    // SHADOW runs the worker-safe POD pipeline for measurement and parity
    // diagnostics. The legacy synchronous graph remains authoritative until
    // every domain has a verified state/ACK adapter, so ACTIVE stays gated.
    if (_mode.load(std::memory_order_acquire) == RuntimeSimulationMode::SHADOW) {
        const auto country_snapshot = std::atomic_load_explicit(
            &_country_snapshot, std::memory_order_acquire);
        RuntimeClimateVerticalReport climate_report;
        bool climate_ok = false;
        RuntimeClimateReferenceFrame trace_frame;
        const RuntimeClimateTracePopResult trace_result =
            _climate_trace.pop_for_day(plan.context.day, trace_frame);
        if (trace_result == RuntimeClimateTracePopResult::CONSUMED) {
            _climate_trace_consumed.fetch_add(1, std::memory_order_relaxed);
            _climate_trace_latest_hash.store(trace_frame.trace_hash,
                                             std::memory_order_release);
        } else {
            _climate_trace_missing.fetch_add(1, std::memory_order_relaxed);
        }
        // A SHADOW Climate day is valid only when the OFF reference has
        // released the matching trace frame. Never silently substitute the
        // latest live environment: doing so would make parity non-replayable.
        const RuntimeEnvironmentSnapshot *climate_environment =
            trace_result == RuntimeClimateTracePopResult::CONSUMED &&
                trace_frame.environment != nullptr
                ? trace_frame.environment.get() : nullptr;
        if (climate_environment != nullptr) {
            const bool climate_planned = _climate_authority.plan_day(
                plan.context.day, *climate_environment, climate_report);
            // plan_day resets the report, so attach the trace metadata only
            // after the authority has filled its execution diagnostics.
            climate_report.reference_state_hash = trace_frame.reference_state_hash;
            climate_report.parity_compared = climate_planned &&
                trace_frame.reference_state_hash != 0;
            climate_report.parity_matched = climate_report.parity_compared &&
                climate_report.state_hash == trace_frame.reference_state_hash;
            if (!climate_planned) {
                // Preserve the authority's first execution/preflight error;
                // a failed plan is not a parity comparison and must not be
                // relabeled as a hash mismatch.
                climate_report.parity_reason[0] = '\0';
                if (climate_report.error[0] == '\0') {
                    runtime_copy_text(climate_report.error,
                                      "climate_execution_failed");
                }
                climate_ok = false;
            } else if (!climate_report.parity_compared) {
                // The trace ring normally refuses to expose a frame before
                // a non-zero reference hash is recorded. Treat a malformed
                // or incomplete frame as a hard input barrier anyway; never
                // let a non-compared day look ready.
                climate_report.parity_reason[0] = '\0';
                _climate_authority.discard_plan();
                climate_report.completed = 0;
                climate_ok = false;
                climate_report.preflight_ok = 0;
                runtime_copy_text(climate_report.error,
                                  "climate_reference_hash_missing");
            } else if (!climate_report.parity_matched) {
                runtime_copy_text(climate_report.parity_reason,
                                  "climate_reference_hash_mismatch");
                // Abort before commit so a failed deterministic comparison
                // cannot advance the worker-owned Climate generation/day.
                _climate_authority.discard_plan();
                climate_report.completed = 0;
                climate_ok = false;
                climate_report.preflight_ok = 0;
                runtime_copy_text(climate_report.error,
                                  "climate_reference_hash_mismatch");
            } else {
                // Only a matching next-state hash may cross the commit
                // boundary. The kernel's plan hash is identical to the
                // committed hash because commit only swaps the two lanes.
                climate_ok = _climate_authority.commit_day(
                    plan.context.day, climate_report);
                if (!climate_ok) {
                    climate_report.parity_reason[0] = '\0';
                    if (climate_report.error[0] == '\0') {
                        runtime_copy_text(climate_report.error,
                                          "climate_commit_failed");
                    }
                } else {
                    runtime_copy_text(climate_report.parity_reason, "ok");
                }
            }
            for (size_t i = 0; i < _climate_pod_parity_reason.size(); ++i) {
                _climate_pod_parity_reason[i].store(climate_report.parity_reason[i],
                                                    std::memory_order_release);
                if (climate_report.parity_reason[i] == '\0') break;
            }
            _climate_pod_reference_hash.store(trace_frame.reference_state_hash,
                                               std::memory_order_release);
            _climate_parity_day.store(plan.context.day, std::memory_order_release);
            _climate_parity_input_generation.store(climate_report.input_generation, std::memory_order_release);
            _climate_parity_base_generation.store(_climate_authority.store().generation, std::memory_order_release);
            _climate_parity_trace_hash.store(trace_frame.trace_hash, std::memory_order_release);
            _climate_pod_parity_compared.store(climate_report.parity_compared != 0,
                                                std::memory_order_release);
            _climate_pod_parity_matched.store(climate_report.parity_matched != 0,
                                               std::memory_order_release);
            if (climate_report.parity_compared && !climate_report.parity_matched) {
                _climate_pod_parity_mismatch_count.fetch_add(1,
                                                              std::memory_order_relaxed);
            }
        } else {
            std::memset(&climate_report, 0, sizeof(climate_report));
            const char *reason = "climate_trace_reference_pending";
            if (trace_result == RuntimeClimateTracePopResult::EMPTY) {
                reason = "climate_trace_missing";
            } else if (trace_result == RuntimeClimateTracePopResult::FUTURE_FRAME) {
                reason = "climate_trace_future_frame";
            }
            runtime_copy_text(climate_report.error, reason);
            climate_report.preflight_ok = 0;
        }
        _climate_pod_ready.store(climate_ok, std::memory_order_release);
        _climate_pod_plan_ms.store(climate_report.plan_ms, std::memory_order_release);
        _climate_pod_replay_ms.store(climate_report.replay_ms, std::memory_order_release);
        _climate_pod_work_units.store(climate_report.work_units, std::memory_order_release);
        _climate_pod_changed_cells.store(climate_report.changed_cells, std::memory_order_release);
        _climate_pod_state_hash.store(climate_report.state_hash, std::memory_order_release);
        for (size_t i = 0; i < _climate_pod_fallback_reason.size(); ++i) {
            _climate_pod_fallback_reason[i].store(climate_report.error[i],
                                                  std::memory_order_release);
            if (climate_report.error[i] == '\0') break;
        }

        RuntimeDayContext diagnostic_context = plan.context;
        diagnostic_context.input_generation = climate_environment != nullptr
            ? climate_environment->generation : 0;

        // Run the consolidated worker-only domain transaction after the
        // Climate trace barrier. This is deliberately a SHADOW diagnostic:
        // it owns an isolated aggregate and never contributes to the
        // authoritative clock, MapData, or implemented-domain mask.
        RuntimeDomainAuthorityPlan authority_plan;
        std::string authority_error;
        bool authority_ok = false;
        double authority_plan_ms = 0.0;
        double authority_replay_ms = 0.0;
        if (climate_ok && climate_environment != nullptr) {
            const auto &authority_stores = _domain_authority_runner.stores();
            const uint32_t country_count = country_snapshot != nullptr
                ? country_snapshot->country_count : authority_stores.country.country_count;
            if (authority_stores.climate.cell_count !=
                    climate_environment->cell_count ||
                authority_stores.country.country_count != country_count ||
                authority_stores.country.cell_count !=
                    climate_environment->cell_count) {
                _domain_authority_runner.reset(
                    climate_environment->cell_count, country_count);
            }
            RuntimeDayContext authority_context = diagnostic_context;
            authority_context.environment = climate_environment;
            const auto plan_started = std::chrono::steady_clock::now();
            authority_ok = _domain_authority_runner.plan_day(
                authority_context, climate_environment,
                country_snapshot.get(), authority_plan, authority_error);
            authority_plan_ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - plan_started).count();
            if (authority_ok) {
                const auto replay_started = std::chrono::steady_clock::now();
                authority_ok = _domain_authority_runner.commit_day(
                    authority_plan, authority_error);
                authority_replay_ms = std::chrono::duration<double, std::milli>(
                    std::chrono::steady_clock::now() - replay_started).count();
            } else {
                _domain_authority_runner.discard_plan();
            }
        } else {
            authority_error = climate_report.error[0] != '\0'
                ? climate_report.error : "climate_reference_barrier_pending";
            _domain_authority_runner.discard_plan();
        }
        if (authority_ok) {
            const RuntimeDomainAuthorityReport &authority_report =
                _domain_authority_runner.report();
            _domain_authority_planned_mask.store(
                authority_report.diagnostic_planned_mask,
                std::memory_order_release);
            _domain_authority_committed_mask.store(
                authority_report.diagnostic_committed_mask,
                std::memory_order_release);
            _domain_authority_ack_count.store(authority_report.ack_count,
                                              std::memory_order_release);
            _domain_authority_input_hash.store(authority_report.input_hash,
                                               std::memory_order_release);
            _domain_authority_state_hash.store(authority_report.state_hash,
                                               std::memory_order_release);
            _domain_authority_plan_ms.store(authority_plan_ms,
                                            std::memory_order_release);
            _domain_authority_replay_ms.store(authority_replay_ms,
                                              std::memory_order_release);
            for (size_t i = 0; i < _domain_authority_fallback_reason.size(); ++i) {
                _domain_authority_fallback_reason[i].store('\0',
                                                          std::memory_order_release);
            }
        } else {
            _domain_authority_planned_mask.store(0, std::memory_order_release);
            _domain_authority_committed_mask.store(0, std::memory_order_release);
            _domain_authority_ack_count.store(0, std::memory_order_release);
            _domain_authority_input_hash.store(0, std::memory_order_release);
            _domain_authority_state_hash.store(0, std::memory_order_release);
            _domain_authority_plan_ms.store(authority_plan_ms,
                                            std::memory_order_release);
            _domain_authority_replay_ms.store(authority_replay_ms,
                                              std::memory_order_release);
            const char *reason = authority_error.empty()
                ? "domain_authority_plan_failed" : authority_error.c_str();
            size_t i = 0;
            for (; i + 1 < _domain_authority_fallback_reason.size() &&
                    reason[i] != '\0'; ++i) {
                _domain_authority_fallback_reason[i].store(
                    reason[i], std::memory_order_release);
            }
            for (; i < _domain_authority_fallback_reason.size(); ++i) {
                _domain_authority_fallback_reason[i].store(
                    '\0', std::memory_order_release);
            }
        }
        uint32_t stage_fallback_count = 0;
        char first_stage_fallback[64]{};
        for (const RuntimeDomainId domain : runtime_domain_stage_order()) {
            if (domain == RuntimeDomainId::COMMIT) continue;
            const RuntimeDomainReport stage_report =
                _authoritative_domains.stage_preflight(
                    domain, diagnostic_context, climate_environment);
            if (stage_report.fallback != 0 || stage_report.preflight_ok == 0) {
                ++stage_fallback_count;
                if (first_stage_fallback[0] == '\0') {
                    runtime_copy_text(first_stage_fallback,
                                      stage_report.fallback_reason);
                }
            }
        }
        _domain_stage_fallback_count.store(stage_fallback_count,
                                           std::memory_order_release);
        for (size_t i = 0; i < _domain_stage_fallback_reason.size(); ++i) {
            _domain_stage_fallback_reason[i].store(first_stage_fallback[i],
                                                   std::memory_order_release);
            if (first_stage_fallback[i] == '\0') break;
        }
        _pod_visual_intents.clear();
        _pod_receipts.clear();
        const bool pipeline_ok = _pod_pipeline.execute_day(
            diagnostic_context, climate_environment, country_snapshot.get(),
            commit, _pod_visual_intents, _pod_receipts);
        const RuntimeDomainPipelineReport &pipeline_report = _pod_pipeline.report();
        _pod_completed_domain_mask.store(pipeline_report.completed_domain_mask,
                                         std::memory_order_release);
        _pod_completed_stage_count.store(
            pipeline_ok ? RUNTIME_DOMAIN_STAGE_COUNT : 0u,
            std::memory_order_release);
        _pod_work_units.store(pipeline_report.work_units, std::memory_order_release);
        _pod_intent_count.store(pipeline_report.intent_count, std::memory_order_release);
        _pod_fallback_count.store(pipeline_report.fallback_count, std::memory_order_release);
        // Do not leak shadow intents into the visual ring. They are only
        // consumed by parity tooling until the ACTIVE ownership gate clears.
        commit.completed_stage_count = 1;
        commit.completed_domain_mask = runtime_domain_mask(RuntimeDomainId::COMMIT);
        commit.dirty_families = RUNTIME_DIRTY_CLOCK;
        commit.work_units = std::max<uint64_t>(1, pipeline_report.work_units);
        commit.preflight_ok = climate_ok ? 1u : 0u;
        return commit;
    }
    // Phase B boundary: the clock commit is the only complete handler until
    // the existing Country/Economy/Effect/Modifier/Climate/Trigger stores have
    // native POD adapters. Keeping the remaining stages uncompleted makes the
    // coverage gap observable instead of accidentally claiming ACTIVE.
    for (uint32_t i = 0; i < plan.stage_count; ++i) {
        RuntimeDomainPlan &stage = plan.stages[i];
        if (stage.domain == RuntimeDomainId::COUNTRY &&
            _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::SHADOW) {
            RuntimeCountryDayContext country_context;
            country_context.day = plan.context.day;
            country_context.speed_scale = plan.context.speed_scale;
            country_context.input_generation = plan.context.input_generation;
            RuntimeCountryDayCommit country_commit;
            RuntimeCountryPodDiagnostics diagnostics;
            const auto country_snapshot = std::atomic_load_explicit(
                &_country_snapshot, std::memory_order_acquire);
            if (country_snapshot && RuntimeCountryPodAdapter::execute_day(
                    *country_snapshot, country_context, country_commit, diagnostics)) {
                std::atomic_store_explicit(&_country_pod_diagnostics,
                    std::make_shared<const RuntimeCountryPodDiagnostics>(diagnostics),
                    std::memory_order_release);
                stage.dirty_families = country_commit.dirty_families;
                stage.work_units = country_commit.research_work_units;
                stage.completed = country_commit.completed;
                commit.dirty_families |= stage.dirty_families;
                commit.work_units += stage.work_units;
                // ACK is intentionally not counted as a complete domain. The
                // adapter is a SHADOW probe until peer domains are POD-safe.
            } else {
                std::atomic_store_explicit(&_country_pod_diagnostics,
                    std::make_shared<const RuntimeCountryPodDiagnostics>(diagnostics),
                    std::memory_order_release);
            }
            continue;
        }
        if (stage.domain != RuntimeDomainId::COMMIT) continue;
        stage.dirty_families = RUNTIME_DIRTY_CLOCK;
        stage.work_units = 1;
        stage.completed = 1;
        commit.dirty_families |= stage.dirty_families;
        commit.work_units += stage.work_units;
        commit.completed_domain_mask |= runtime_domain_mask(stage.domain);
        ++commit.completed_stage_count;
    }
    return commit;
}

void NativeSimulationHost::publish_day(
        int64_t from_day, int64_t day,
        const RuntimeDayCommit &day_commit,
        const std::vector<RuntimeCommandReceipt> &day_receipts) {
    const uint64_t next_hash = mix_hash(
        _state_hash.load(std::memory_order_relaxed), static_cast<uint64_t>(day));
    _state_hash.store(next_hash, std::memory_order_release);
    // Publish scalar header fields before the generation release store. A
    // non-blocking reader that observes this generation therefore cannot see
    // metadata from the preceding day even when the visual ring is saturated.
    const uint64_t generation = _generation.load(std::memory_order_relaxed) + 1;
    constexpr std::array<uint32_t, RUNTIME_DIRTY_FAMILY_COUNT> FAMILY_BITS{
        RUNTIME_DIRTY_CLOCK,
        RUNTIME_DIRTY_COUNTRY_STATE,
        RUNTIME_DIRTY_COUNTRY_TERRITORY,
        RUNTIME_DIRTY_COUNTRY_VISUAL_ERA,
        RUNTIME_DIRTY_CLIMATE_FIELDS,
        RUNTIME_DIRTY_WEATHER,
        RUNTIME_DIRTY_ECONOMY_UI,
        RUNTIME_DIRTY_EVENTS,
        RUNTIME_DIRTY_OVERLAY,
    };
    for (size_t family_index = 0; family_index < FAMILY_BITS.size(); ++family_index) {
        if ((day_commit.dirty_families & FAMILY_BITS[family_index]) != 0) {
            _dirty_family_generations[family_index].store(
                generation, std::memory_order_relaxed);
        }
    }
    _latest_from_day.store(from_day, std::memory_order_relaxed);
    _latest_committed_day.store(day, std::memory_order_relaxed);
    _latest_dirty_families.store(day_commit.dirty_families, std::memory_order_relaxed);
    _latest_receipt_count.store(static_cast<uint32_t>(
        std::min<size_t>(day_receipts.size(), std::numeric_limits<uint32_t>::max())),
        std::memory_order_relaxed);
    const uint64_t produced_at_us = now_us();
    _latest_produced_at_us.store(produced_at_us, std::memory_order_release);
    _generation.store(generation, std::memory_order_release);
    _last_commit_produced_at_us.store(produced_at_us, std::memory_order_release);
    const uint64_t last_visual = _last_visual_publish_us.load(std::memory_order_relaxed);
    // Visual state is capped at 20 Hz. Commands and non-clock dirty families
    // bypass the cap so a user action or major event is visible immediately.
    const bool force_visual = !day_receipts.empty() ||
        (day_commit.dirty_families & ~RUNTIME_DIRTY_CLOCK) != 0;
    if (!force_visual && last_visual != 0 && produced_at_us - last_visual < 50000u) {
        _snapshot_publish_throttled_count.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    uint32_t index = 0;
    if (!_snapshots.try_begin_write(index)) return;
    RuntimeCommit &commit = _snapshots.write_buffer(index);
    commit.header = RuntimeCommitHeader{};
    commit.header.generation = generation;
    commit.header.from_day = from_day;
    commit.header.committed_day = day;
    commit.header.produced_at_us = produced_at_us;
    commit.header.dirty_families = day_commit.dirty_families;
    commit.header.state_hash = _state_hash.load(std::memory_order_acquire);
    commit.header.command_receipt_count = static_cast<uint32_t>(
        std::min<size_t>(day_receipts.size(), std::numeric_limits<uint32_t>::max()));
    for (size_t family_index = 0; family_index < FAMILY_BITS.size(); ++family_index) {
        commit.header.dirty_family_generations[family_index] =
            _dirty_family_generations[family_index].load(std::memory_order_acquire);
    }
    commit.visual_intents.clear();
    commit.receipts.clear();
    commit.receipts.reserve(day_receipts.size());
    for (const RuntimeCommandReceipt &receipt : day_receipts) {
        commit.receipts.push_back(receipt);
    }
    _snapshots.publish(index);
    _last_visual_publish_us.store(produced_at_us, std::memory_order_release);
    _last_commit_produced_at_us.store(commit.header.produced_at_us,
                                      std::memory_order_release);
}

void NativeSimulationHost::set_fault(const char *code) {
    _worker_fault_count.fetch_add(1, std::memory_order_relaxed);
    const char *value = code ? code : "unknown";
    size_t i = 0;
    for (; i + 1 < _fault_code.size() && value[i] != '\0'; ++i) {
        _fault_code[i].store(value[i], std::memory_order_relaxed);
    }
    for (; i < _fault_code.size(); ++i) {
        _fault_code[i].store('\0', std::memory_order_relaxed);
    }
    _state.store(RuntimeWorkerState::FAULTED, std::memory_order_release);
}

bool NativeSimulationHost::request_save(uint64_t request_id) {
    const RuntimeWorkerState current = _state.load(std::memory_order_acquire);
    if (request_id == 0 || current == RuntimeWorkerState::STOPPED ||
        current == RuntimeWorkerState::STOPPING ||
        current == RuntimeWorkerState::FAULTED ||
        _stop_requested.load(std::memory_order_acquire)) {
        return false;
    }
    uint64_t expected_request = 0;
    if (!_save_request_id.compare_exchange_strong(expected_request, request_id,
            std::memory_order_acq_rel, std::memory_order_relaxed)) {
        return false;
    }
    _save_consumed_request_id.store(0, std::memory_order_release);
    std::atomic_store_explicit(&_save_bundle,
        std::shared_ptr<const RuntimeSaveBundle>(), std::memory_order_release);
    // Publish the flag only after the ID.  The worker's acquire exchange then
    // cannot observe a request without its matching identifier.
    _save_requested.store(true, std::memory_order_release);
    _control_cv.notify_all();
    return true;
}

std::shared_ptr<const RuntimeSaveBundle>
NativeSimulationHost::poll_save(uint64_t request_id) const {
    const auto bundle = std::atomic_load_explicit(&_save_bundle, std::memory_order_acquire);
    if (bundle == nullptr ||
        (request_id != 0 && bundle->request_id != request_id)) {
        return nullptr;
    }
    uint64_t expected = 0;
    if (!_save_consumed_request_id.compare_exchange_strong(
            expected, bundle->request_id, std::memory_order_acq_rel,
            std::memory_order_acquire)) {
        return nullptr;
    }
    return bundle;
}

bool NativeSimulationHost::restore_bundle(const uint8_t *bytes, size_t size,
                                          std::string &error) {
    if (_state.load(std::memory_order_acquire) != RuntimeWorkerState::STOPPED) {
        error = "runtime_restore_requires_stopped_worker";
        return false;
    }
    // Fixed v2 scalar header (through section_mask) plus the trailing checksum.
    // The command tail is mandatory in v2 because producer cursors are part of
    // the deterministic restore contract.
    constexpr size_t SCALAR_HEADER_SIZE = 89u;
    constexpr size_t MIN_BUNDLE_SIZE = SCALAR_HEADER_SIZE + 4u + 4u +
        (256u * sizeof(uint64_t)) + sizeof(uint64_t) + sizeof(uint64_t);
    if (bytes == nullptr || size < SCALAR_HEADER_SIZE + sizeof(uint64_t)) {
        error = "runtime_bundle_truncated";
        return false;
    }
    if (std::memcmp(bytes, "PKSR", 4) != 0) {
        error = "runtime_bundle_magic_invalid";
        return false;
    }
    const auto read_u32 = [bytes, size](size_t offset, uint32_t &out) {
        if (offset > size || size - offset < 4u) return false;
        out = static_cast<uint32_t>(bytes[offset]) |
            (static_cast<uint32_t>(bytes[offset + 1u]) << 8u) |
            (static_cast<uint32_t>(bytes[offset + 2u]) << 16u) |
            (static_cast<uint32_t>(bytes[offset + 3u]) << 24u);
        return true;
    };
    const auto read_u16 = [bytes, size](size_t offset, uint16_t &out) {
        if (offset > size || size - offset < 2u) return false;
        out = static_cast<uint16_t>(bytes[offset]) |
            static_cast<uint16_t>(static_cast<uint16_t>(bytes[offset + 1u]) << 8u);
        return true;
    };
    const auto read_u64 = [bytes, size](size_t offset, uint64_t &out) {
        if (offset > size || size - offset < 8u) return false;
        out = 0;
        for (uint32_t i = 0; i < 8u; ++i)
            out |= static_cast<uint64_t>(bytes[offset + i]) << (i * 8u);
        return true;
    };
    uint32_t version = 0;
    if (!read_u32(4u, version) || version != RUNTIME_SAVE_BUNDLE_VERSION) {
        error = "runtime_bundle_version_incompatible";
        return false;
    }
    uint64_t encoded_checksum = 0;
    if (!read_u64(size - sizeof(uint64_t), encoded_checksum)) {
        error = "runtime_bundle_checksum_missing";
        return false;
    }
    uint64_t checksum = 1469598103934665603ull;
    for (size_t i = 0; i + sizeof(uint64_t) < size; ++i) {
        checksum ^= static_cast<uint64_t>(bytes[i]);
        checksum *= 1099511628211ull;
    }
    if (checksum != encoded_checksum) {
        error = "runtime_bundle_checksum_failed";
        return false;
    }
    RuntimeSaveBundle parsed;
    parsed.bytes.assign(bytes, bytes + size);
    parsed.checksum = encoded_checksum;
    parsed.bundle_version = version;
    uint64_t committed_day_bits = 0;
    if (!read_u64(8u, parsed.request_id) ||
        !read_u64(16u, committed_day_bits)) {
        error = "runtime_bundle_header_invalid";
        return false;
    }
    // Decode the signed fields through an integer temporary.  Reinterpreting
    // an int64_t object as uint64_t violates strict-aliasing and is not
    // required by the endian-stable wire format.
    std::memcpy(&parsed.committed_day, &committed_day_bits,
                sizeof(parsed.committed_day));
    uint64_t speed_bits = 0;
    uint64_t generation = 0;
    uint64_t state_hash = 0;
    uint64_t environment_generation = 0;
    uint64_t environment_day_bits = 0;
    uint64_t anomaly_bits = 0;
    uint64_t debt_bits = 0;
    uint32_t runtime_domain_abi_version = 0;
    uint32_t section_mask = 0;
    if (!read_u64(24u, speed_bits) || !read_u64(33u, generation) ||
        !read_u64(41u, state_hash) || !read_u64(49u, environment_generation) ||
        !read_u64(57u, environment_day_bits) || !read_u64(65u, anomaly_bits) ||
        !read_u64(73u, debt_bits) || !read_u32(81u, runtime_domain_abi_version) ||
        !read_u32(85u, section_mask)) {
        error = "runtime_bundle_header_invalid";
        return false;
    }
    std::memcpy(&parsed.speed_days_per_second, &speed_bits, sizeof(double));
    parsed.paused = bytes[32u] != 0;
    parsed.generation = generation;
    parsed.state_hash = state_hash;
    parsed.environment_generation = environment_generation;
    parsed.runtime_domain_abi_version = runtime_domain_abi_version;
    parsed.section_mask = section_mask;
    std::memcpy(&parsed.environment_day, &environment_day_bits, sizeof(int64_t));
    std::memcpy(&parsed.climate_anomaly, &anomaly_bits, sizeof(double));
    std::memcpy(&parsed.time_debt_days, &debt_bits, sizeof(double));
    if (parsed.committed_day < 0 || parsed.environment_day < 0 ||
        !std::isfinite(parsed.speed_days_per_second) ||
        parsed.speed_days_per_second < 0.0 ||
        !std::isfinite(parsed.climate_anomaly) ||
        !std::isfinite(parsed.time_debt_days) ||
        parsed.time_debt_days < 0.0 || parsed.time_debt_days > 100.0) {
        error = "runtime_bundle_value_invalid";
        return false;
    }
    if (parsed.runtime_domain_abi_version != RUNTIME_DOMAIN_ABI_VERSION) {
        error = "runtime_bundle_domain_abi_incompatible";
        return false;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_RUNTIME_ENVELOPE) == 0 ||
        (parsed.section_mask & ~(RUNTIME_SAVE_SECTION_RUNTIME_ENVELOPE |
                                 RUNTIME_SAVE_SECTION_DOMAIN_POD |
                                 RUNTIME_SAVE_SECTION_CLIMATE)) != 0) {
        error = "runtime_bundle_section_mask_invalid";
        return false;
    }
    if (size < MIN_BUNDLE_SIZE) {
        error = "runtime_bundle_tail_missing";
        return false;
    }
    constexpr uint32_t PRODUCER_CURSOR_MARKER = 0x31514350u; // "PCQ1"
    size_t cursor = SCALAR_HEADER_SIZE;
    const size_t payload_end = size - sizeof(uint64_t);
    uint32_t command_count = 0;
    if (!read_u32(cursor, command_count) ||
        command_count > RUNTIME_COMMAND_QUEUE_CAPACITY) {
        error = "runtime_bundle_command_count_invalid";
        return false;
    }
    cursor += 4u;
    parsed.pending_commands.reserve(command_count);
    for (uint32_t i = 0; i < command_count; ++i) {
        RuntimeCommandPacket packet;
        RuntimeCommandEnvelope &envelope = packet.envelope;
        uint64_t requested_day_bits = 0;
        uint64_t effective_day_bits = 0;
        if (!read_u64(cursor, envelope.request_id) ||
            !read_u32(cursor + 8u, envelope.producer_id) ||
            !read_u64(cursor + 12u, envelope.sequence) ||
            !read_u64(cursor + 20u, envelope.observed_generation) ||
            !read_u64(cursor + 28u, requested_day_bits) ||
            !read_u64(cursor + 36u, effective_day_bits) ||
            !read_u16(cursor + 44u, envelope.domain) ||
            !read_u16(cursor + 46u, envelope.opcode) ||
            !read_u32(cursor + 48u, envelope.payload_size)) {
            error = "runtime_bundle_command_truncated";
            return false;
        }
        std::memcpy(&envelope.requested_day, &requested_day_bits,
                    sizeof(envelope.requested_day));
        std::memcpy(&envelope.effective_day, &effective_day_bits,
                    sizeof(envelope.effective_day));
        envelope.payload_offset = 0;
        cursor += 52u;
        if (envelope.request_id == 0 || envelope.requested_day < 0 ||
            envelope.effective_day < 0 || envelope.payload_size > RUNTIME_MAX_COMMAND_PAYLOAD ||
            envelope.domain > static_cast<uint16_t>(RuntimeDomainId::COMMIT) ||
            envelope.opcode == 0 ||
            cursor > payload_end || envelope.payload_size > payload_end - cursor) {
            error = "runtime_bundle_command_invalid";
            return false;
        }
        if (envelope.payload_size > 0) {
            std::memcpy(packet.payload.data(), bytes + cursor,
                        envelope.payload_size);
        }
        cursor += envelope.payload_size;
        parsed.pending_commands.push_back(std::move(packet));
    }
    uint32_t marker = 0;
    if (!read_u32(cursor, marker) || marker != PRODUCER_CURSOR_MARKER) {
        error = "runtime_bundle_producer_cursor_missing";
        return false;
    }
    cursor += 4u;
    for (uint64_t &sequence : parsed.producer_sequences) {
        if (!read_u64(cursor, sequence)) {
            error = "runtime_bundle_producer_cursor_truncated";
            return false;
        }
        cursor += 8u;
    }
    if (!read_u64(cursor, parsed.fallback_producer_sequence)) {
        error = "runtime_bundle_producer_cursor_invalid";
        return false;
    }
    cursor += 8u;
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_DOMAIN_POD) != 0) {
        constexpr uint32_t DOMAIN_SECTION_MARKER = 0x32445044u; // "DPD2"
        uint32_t marker = 0;
        uint32_t section_size = 0;
        const bool section_header_available = cursor <= payload_end &&
            payload_end - cursor >= 8u;
        if (!section_header_available || !read_u32(cursor, marker) ||
            marker != DOMAIN_SECTION_MARKER ||
            !read_u32(cursor + 4u, section_size) ||
            section_size > 64u * 1024u * 1024u ||
            payload_end - cursor < 16u ||
            section_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_domain_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.domain_pod_bytes.assign(bytes + cursor, bytes + cursor + section_size);
        cursor += section_size;
        uint64_t section_checksum = 0;
        if (!read_u64(cursor, section_checksum)) {
            error = "runtime_bundle_domain_section_checksum_missing";
            return false;
        }
        uint64_t computed_section_checksum = 1469598103934665603ull;
        for (const uint8_t byte : parsed.domain_pod_bytes) {
            computed_section_checksum ^= static_cast<uint64_t>(byte);
            computed_section_checksum *= 1099511628211ull;
        }
        if (computed_section_checksum != section_checksum) {
            error = "runtime_bundle_domain_section_checksum_failed";
            return false;
        }
        cursor += 8u;
    }
    if ((parsed.section_mask & RUNTIME_SAVE_SECTION_CLIMATE) != 0) {
        constexpr uint32_t CLIMATE_SECTION_MARKER = 0x324d4c43u; // CLM2
        uint32_t climate_marker = 0;
        uint32_t climate_size = 0;
        if (cursor > payload_end || payload_end - cursor < 16u ||
            !read_u32(cursor, climate_marker) ||
            !read_u32(cursor + 4u, climate_size) ||
            climate_marker != CLIMATE_SECTION_MARKER ||
            climate_size > 64u * 1024u * 1024u ||
            climate_size > payload_end - cursor - 16u) {
            error = "runtime_bundle_climate_section_invalid";
            return false;
        }
        cursor += 8u;
        parsed.climate_bytes.assign(bytes + cursor, bytes + cursor + climate_size);
        cursor += climate_size;
        uint64_t climate_checksum = 0;
        if (!read_u64(cursor, climate_checksum)) {
            error = "runtime_bundle_climate_section_checksum_missing";
            return false;
        }
        uint64_t computed = 1469598103934665603ull;
        for (const uint8_t byte : parsed.climate_bytes) {
            computed ^= static_cast<uint64_t>(byte);
            computed *= 1099511628211ull;
        }
        if (computed != climate_checksum) {
            error = "runtime_bundle_climate_section_checksum_failed";
            return false;
        }
        cursor += 8u;
    }
    if (cursor != payload_end) {
        error = "runtime_bundle_producer_cursor_invalid";
        return false;
    }
    _pending_restore_bundle = std::move(parsed);
    _has_pending_restore = true;
    return true;
}

void NativeSimulationHost::build_save_bundle(
        uint64_t request_id,
        const std::vector<RuntimeCommandPacket> &pending_commands) {
    auto bundle = std::make_shared<RuntimeSaveBundle>();
    bundle->request_id = request_id;
    bundle->bundle_version = RUNTIME_SAVE_BUNDLE_VERSION;
    bundle->runtime_domain_abi_version = RUNTIME_DOMAIN_ABI_VERSION;
    bundle->section_mask = RUNTIME_SAVE_SECTION_RUNTIME_ENVELOPE |
        RUNTIME_SAVE_SECTION_DOMAIN_POD;
    bundle->committed_day = _committed_day.load(std::memory_order_acquire);
    bundle->paused = _paused.load(std::memory_order_acquire);
    bundle->speed_days_per_second = _speed_days_per_second.load(std::memory_order_acquire);
    bundle->generation = _generation.load(std::memory_order_acquire);
    bundle->state_hash = _state_hash.load(std::memory_order_acquire);
    bundle->environment_generation = _environment_generation.load(
        std::memory_order_acquire);
    bundle->environment_day = _environment_day.load(std::memory_order_acquire);
    bundle->time_debt_days = _time_debt_days.load(std::memory_order_acquire);
    bundle->pending_commands = pending_commands;
    for (size_t i = 0; i < _producer_sequences.size(); ++i) {
        bundle->producer_sequences[i] = _producer_sequences[i].load(
            std::memory_order_acquire);
    }
    bundle->fallback_producer_sequence = _fallback_producer_sequence.load(
        std::memory_order_acquire);
    if (const auto environment = environment_snapshot()) {
        bundle->climate_anomaly = environment->climate_anomaly;
    }
    _pod_pipeline.serialize(bundle->domain_pod_bytes);
    const bool include_climate = _climate_authority.store().cell_count != 0;
    if (include_climate) {
        std::string climate_save_error;
        if (!_climate_authority.serialize(bundle->climate_bytes, climate_save_error)) {
            set_fault(climate_save_error.empty() ? "climate_save_encode_failed" :
                      climate_save_error.c_str());
            return;
        }
        bundle->section_mask |= RUNTIME_SAVE_SECTION_CLIMATE;
    }

    // PKSR v2 is an endian-stable runtime envelope. The fixed scalar header
    // carries an explicit ABI/section mask, followed by a bounded pending
    // command tail and producer cursors. The checksum remains the final eight
    // bytes and the complete tail is mandatory for v2 restores.
    bundle->bytes.reserve(4 + 4 + 8 * 10 + 1 + 4 + 4 +
        bundle->pending_commands.size() * (8 + 4 + 8 + 8 + 8 + 8 + 2 + 2 + 4 +
                                           RUNTIME_MAX_COMMAND_PAYLOAD) +
        bundle->producer_sequences.size() * 8 + 8 + 8);
    const auto append_bytes = [&bundle](const void *data, size_t size) {
        const size_t offset = bundle->bytes.size();
        bundle->bytes.resize(offset + size);
        std::memcpy(bundle->bytes.data() + offset, data, size);
    };
    const auto append_u32_le = [&append_bytes](uint32_t value) {
        const std::array<uint8_t, 4> bytes{
            static_cast<uint8_t>(value & 0xffu),
            static_cast<uint8_t>((value >> 8u) & 0xffu),
            static_cast<uint8_t>((value >> 16u) & 0xffu),
            static_cast<uint8_t>((value >> 24u) & 0xffu),
        };
        append_bytes(bytes.data(), bytes.size());
    };
    const auto append_u16_le = [&append_bytes](uint16_t value) {
        const std::array<uint8_t, 2> bytes{
            static_cast<uint8_t>(value & 0xffu),
            static_cast<uint8_t>((value >> 8u) & 0xffu),
        };
        append_bytes(bytes.data(), bytes.size());
    };
    const auto append_u64_le = [&append_bytes](uint64_t value) {
        std::array<uint8_t, 8> bytes{};
        for (uint32_t i = 0; i < bytes.size(); ++i)
            bytes[i] = static_cast<uint8_t>((value >> (i * 8u)) & 0xffu);
        append_bytes(bytes.data(), bytes.size());
    };
    const auto append_i64_le = [&append_u64_le](int64_t value) {
        append_u64_le(static_cast<uint64_t>(value));
    };
    const auto append_f64_le = [&append_u64_le](double value) {
        uint64_t bits = 0;
        static_assert(sizeof(bits) == sizeof(value));
        std::memcpy(&bits, &value, sizeof(bits));
        append_u64_le(bits);
    };
    const char magic[4] = {'P', 'K', 'S', 'R'};
    const uint32_t version = RUNTIME_SAVE_BUNDLE_VERSION;
    const uint8_t paused = bundle->paused ? 1u : 0u;
    append_bytes(magic, sizeof(magic));
    append_u32_le(version);
    append_u64_le(bundle->request_id);
    append_i64_le(bundle->committed_day);
    append_f64_le(bundle->speed_days_per_second);
    append_bytes(&paused, sizeof(paused));
    append_u64_le(bundle->generation);
    append_u64_le(bundle->state_hash);
    append_u64_le(bundle->environment_generation);
    append_i64_le(bundle->environment_day);
    append_f64_le(bundle->climate_anomaly);
    append_f64_le(bundle->time_debt_days);
    append_u32_le(RUNTIME_DOMAIN_ABI_VERSION);
    append_u32_le(bundle->section_mask);

    const uint32_t pending_count = static_cast<uint32_t>(std::min<size_t>(
        bundle->pending_commands.size(), RUNTIME_COMMAND_QUEUE_CAPACITY));
    append_u32_le(pending_count);
    for (uint32_t i = 0; i < pending_count; ++i) {
        const RuntimeCommandPacket &command = bundle->pending_commands[i];
        const RuntimeCommandEnvelope &envelope = command.envelope;
        append_u64_le(envelope.request_id);
        append_u32_le(envelope.producer_id);
        append_u64_le(envelope.sequence);
        append_u64_le(envelope.observed_generation);
        append_i64_le(envelope.requested_day);
        append_i64_le(envelope.effective_day);
        append_u16_le(envelope.domain);
        append_u16_le(envelope.opcode);
        append_u32_le(envelope.payload_size);
        if (envelope.payload_size > 0) {
            append_bytes(command.payload.data(), envelope.payload_size);
        }
    }
    // A marker separates optional command records from producer cursors. This
    // lets a future PKSR decoder reject a truncated tail instead of treating
    // arbitrary bytes as sequence state.
    constexpr uint32_t PRODUCER_CURSOR_MARKER = 0x31514350u; // "PCQ1"
    append_u32_le(PRODUCER_CURSOR_MARKER);
    for (uint64_t sequence : bundle->producer_sequences)
        append_u64_le(sequence);
    append_u64_le(bundle->fallback_producer_sequence);
    constexpr uint32_t DOMAIN_SECTION_MARKER = 0x32445044u; // "DPD2"
    append_u32_le(DOMAIN_SECTION_MARKER);
    append_u32_le(static_cast<uint32_t>(std::min<size_t>(
        bundle->domain_pod_bytes.size(), 64u * 1024u * 1024u)));
    const uint32_t domain_section_size = static_cast<uint32_t>(std::min<size_t>(
        bundle->domain_pod_bytes.size(), 64u * 1024u * 1024u));
    if (domain_section_size > 0) {
        append_bytes(bundle->domain_pod_bytes.data(), domain_section_size);
    }
    uint64_t domain_checksum = 1469598103934665603ull;
    for (uint32_t i = 0; i < domain_section_size; ++i) {
        domain_checksum ^= static_cast<uint64_t>(bundle->domain_pod_bytes[i]);
        domain_checksum *= 1099511628211ull;
    }
    append_u64_le(domain_checksum);

    if (include_climate) {
        constexpr uint32_t CLIMATE_SECTION_MARKER = 0x324d4c43u; // "CLM2"
        append_u32_le(CLIMATE_SECTION_MARKER);
        const uint32_t climate_section_size = static_cast<uint32_t>(std::min<size_t>(
            bundle->climate_bytes.size(), 64u * 1024u * 1024u));
        append_u32_le(climate_section_size);
        if (climate_section_size > 0)
            append_bytes(bundle->climate_bytes.data(), climate_section_size);
        uint64_t climate_checksum = 1469598103934665603ull;
        for (uint32_t i = 0; i < climate_section_size; ++i) {
            climate_checksum ^= static_cast<uint64_t>(bundle->climate_bytes[i]);
            climate_checksum *= 1099511628211ull;
        }
        append_u64_le(climate_checksum);
    }

    uint64_t checksum = 1469598103934665603ull;
    for (uint8_t byte : bundle->bytes) {
        checksum ^= static_cast<uint64_t>(byte);
        checksum *= 1099511628211ull;
    }
    bundle->checksum = checksum;
    append_u64_le(bundle->checksum);

    _save_consumed_request_id.store(0, std::memory_order_release);
    std::atomic_store_explicit(&_save_bundle,
        std::shared_ptr<const RuntimeSaveBundle>(std::move(bundle)),
        std::memory_order_release);
}

void NativeSimulationHost::worker_main() {
#if defined(_WIN32)
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_BELOW_NORMAL);
#endif
    _state.store(_paused.load(std::memory_order_acquire)
            ? RuntimeWorkerState::PAUSED : RuntimeWorkerState::RUNNING,
            std::memory_order_release);
    auto last = std::chrono::steady_clock::now();
    // Allocate the bounded protocol capacity once when the worker starts.
    // Daily command processing must not grow a vector in the simulation hot
    // loop when a UI burst happens to exceed the usual batch size.
    std::vector<RuntimeCommandPacket> pending_commands;
    pending_commands.reserve(RUNTIME_COMMAND_QUEUE_CAPACITY);
    size_t pending_begin = 0;
    if (!_worker_initial_pending_commands.empty()) {
        pending_commands = std::move(_worker_initial_pending_commands);
    }
    std::vector<RuntimeCommandReceipt> day_receipts;
    day_receipts.reserve(RUNTIME_RECEIPT_QUEUE_CAPACITY);
    bool pending_commands_dirty = !pending_commands.empty();
    const auto compact_pending_commands = [&](bool force = false) {
        if (pending_begin == 0) return;
        if (pending_begin >= pending_commands.size()) {
            pending_commands.clear();
            pending_begin = 0;
            pending_commands_dirty = false;
            return;
        }
        // Front consumption is the common path. Compact only after a sizeable
        // prefix is dead so daily command handling stays O(1) amortized while
        // a save still receives a contiguous active tail.
        if (!force && pending_begin < 256u && pending_begin * 2u < pending_commands.size()) return;
        const auto active_begin = pending_commands.begin() +
            static_cast<ptrdiff_t>(pending_begin);
        std::move(active_begin, pending_commands.end(), pending_commands.begin());
        pending_commands.resize(pending_commands.size() - pending_begin);
        pending_begin = 0;
    };
    try {
        while (!_stop_requested.load(std::memory_order_acquire)) {
            if (_stop_requested.load(std::memory_order_acquire)) break;

            if (_save_requested.exchange(false, std::memory_order_acq_rel)) {
                const uint64_t request_id = _save_request_id.load(std::memory_order_acquire);
                // Commands in the lock-free ingress queue are already
                // accepted but not yet visible in the worker-local list. Move
                // them across the same boundary before encoding the bundle so
                // SAVE_REQUEST never loses an accepted command.
                RuntimeCommandPacket queued;
                while (pop_command(queued)) {
                    pending_commands.push_back(queued);
                    pending_commands_dirty = true;
                }
                compact_pending_commands(true);
                _state.store(RuntimeWorkerState::SAVE_PENDING, std::memory_order_release);
                build_save_bundle(request_id, pending_commands);
                _save_request_id.store(0, std::memory_order_release);
                _state.store(_paused.load(std::memory_order_acquire)
                        ? RuntimeWorkerState::PAUSED : RuntimeWorkerState::RUNNING,
                        std::memory_order_release);
                last = std::chrono::steady_clock::now();
                continue;
            }

            const bool paused = _paused.load(std::memory_order_acquire);
            const double speed = _speed_days_per_second.load(std::memory_order_acquire);
            if (paused || speed <= 0.0 || !std::isfinite(speed)) {
                if (_stop_requested.load(std::memory_order_acquire)) break;
                _state.store(RuntimeWorkerState::PAUSED, std::memory_order_release);
                last = std::chrono::steady_clock::now();
                std::unique_lock<std::mutex> lock(_control_mutex);
                _control_cv.wait(lock, [&] {
                    return _stop_requested.load(std::memory_order_acquire) ||
                        _save_requested.load(std::memory_order_acquire) ||
                        !_paused.load(std::memory_order_acquire) ||
                        _speed_days_per_second.load(std::memory_order_acquire) > 0.0;
                });
                continue;
            }
            if (_stop_requested.load(std::memory_order_acquire)) break;
            _state.store(RuntimeWorkerState::RUNNING, std::memory_order_release);
            RuntimeCommandPacket incoming;
            while (pop_command(incoming)) {
                pending_commands.push_back(incoming);
                pending_commands_dirty = true;
            }
            const auto now = std::chrono::steady_clock::now();
            const double elapsed = std::chrono::duration<double>(now - last).count();
            last = now;
            double debt = std::min(100.0,
                _time_debt_days.load(std::memory_order_relaxed) + elapsed * speed);
            int64_t target_days = static_cast<int64_t>(debt);
            if (target_days <= 0) {
                _time_debt_days.store(debt, std::memory_order_release);
                const double seconds_until_day = std::max(0.001, (1.0 - debt) / speed);
                std::unique_lock<std::mutex> lock(_control_mutex);
                _control_cv.wait_until(lock, std::chrono::steady_clock::now() +
                    std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                        std::chrono::duration<double>(seconds_until_day)));
                continue;
            }
            target_days = std::min<int64_t>(target_days, 8);
            debt -= static_cast<double>(target_days);
            _time_debt_days.store(std::min(100.0, debt), std::memory_order_release);
            for (int64_t step = 0; step < target_days; ++step) {
                if (_stop_requested.load(std::memory_order_acquire)) break;
                const int64_t from_day = _committed_day.load(std::memory_order_acquire);
                const int64_t day = from_day + 1;
                day_receipts.clear();
                if (pending_commands_dirty) {
                    std::stable_sort(pending_commands.begin() +
                        static_cast<ptrdiff_t>(pending_begin), pending_commands.end(),
                    [](const RuntimeCommandPacket &lhs, const RuntimeCommandPacket &rhs) {
                        const RuntimeCommandEnvelope &a = lhs.envelope;
                        const RuntimeCommandEnvelope &b = rhs.envelope;
                        if (a.effective_day != b.effective_day) return a.effective_day < b.effective_day;
                        if (a.producer_id != b.producer_id) return a.producer_id < b.producer_id;
                        if (a.sequence != b.sequence) return a.sequence < b.sequence;
                        return a.request_id < b.request_id;
                    });
                    pending_commands_dirty = false;
                }
                size_t consumed_commands = pending_begin;
                for (; consumed_commands < pending_commands.size(); ++consumed_commands) {
                    const RuntimeCommandPacket &command = pending_commands[consumed_commands];
                    if (command.envelope.effective_day > day) break;
                    RuntimeCommandReceipt receipt;
                    receipt.request_id = command.envelope.request_id;
                    receipt.producer_id = command.envelope.producer_id;
                    receipt.sequence = command.envelope.sequence;
                    receipt.effective_day = std::max(command.envelope.effective_day, day);
                    receipt.generation = _generation.load(std::memory_order_relaxed) + 1;
                    const bool domain_valid =
                        command.envelope.domain >= static_cast<uint16_t>(RuntimeDomainId::COUNTRY) &&
                        command.envelope.domain <= static_cast<uint16_t>(RuntimeDomainId::COMMIT);
                    const bool domain_implemented = domain_valid &&
                        (implemented_domain_mask() & runtime_domain_mask(
                            static_cast<RuntimeDomainId>(command.envelope.domain))) != 0;
                    const bool payload_valid =
                        command.envelope.payload_offset <= RUNTIME_MAX_COMMAND_PAYLOAD &&
                        command.envelope.payload_size <= RUNTIME_MAX_COMMAND_PAYLOAD &&
                        command.envelope.payload_offset + command.envelope.payload_size <=
                            RUNTIME_MAX_COMMAND_PAYLOAD;
                    if (!payload_valid) {
                        receipt.code = RuntimeReceiptCode::INVALID_PAYLOAD;
                    } else if (!domain_implemented || command.envelope.opcode == 0) {
                        // Unknown domain/opcode is a deterministic preflight
                        // rejection. It remains a receipt, never a dropped
                        // command, so callers can reconcile their request.
                        receipt.code = RuntimeReceiptCode::PREFLIGHT_REJECTED;
                    } else {
                        receipt.code = RuntimeReceiptCode::OK;
                    }
                    day_receipts.push_back(receipt);
                    push_receipt(receipt);
                }
                if (consumed_commands > 0) {
                    pending_begin = consumed_commands;
                    compact_pending_commands();
                }
                const auto environment = environment_snapshot();
                RuntimeDayPlan day_plan = build_day_plan(
                    day, speed, environment.get());
                const RuntimeDayCommit day_commit = execute_day_plan(day_plan);
                if (day_commit.preflight_ok == 0) {
                    // An input/reference barrier failure must not advance the
                    // committed clock. Wait for the main thread to publish
                    // the matching reference or for a control message; this
                    // is a condition-variable wait, not a polling sleep.
                    _time_debt_days.store(std::min(100.0,
                        _time_debt_days.load(std::memory_order_relaxed) + 1.0),
                        std::memory_order_release);
                    const uint64_t trace_signal =
                        _climate_trace_signal.load(std::memory_order_acquire);
                    std::unique_lock<std::mutex> lock(_control_mutex);
                    _control_cv.wait(lock, [&] {
                        return _stop_requested.load(std::memory_order_acquire) ||
                            _save_requested.load(std::memory_order_acquire) ||
                            _paused.load(std::memory_order_acquire) ||
                            _climate_trace_signal.load(std::memory_order_acquire) !=
                                trace_signal ||
                            _climate_trace.consumable_depth() != 0;
                    });
                    break;
                }
                if (day_commit.completed_stage_count == day_plan.stage_count &&
                    day_plan.stage_count == RUNTIME_DOMAIN_STAGE_COUNT &&
                    day_commit.completed_domain_mask == RUNTIME_ALL_DOMAIN_MASK &&
                    implemented_domain_mask() == RUNTIME_ALL_DOMAIN_MASK) {
                    _graph_coverage_complete.store(true, std::memory_order_release);
                    _authority_ready.store(true, std::memory_order_release);
                }
                _last_day_stage_count.store(day_plan.stage_count,
                                            std::memory_order_release);
                _last_day_completed_stages.store(day_commit.completed_stage_count,
                                                 std::memory_order_release);
                _last_day_work_units.store(day_commit.work_units,
                                           std::memory_order_release);
                _committed_day.store(day, std::memory_order_release);
                _completed_days.fetch_add(1, std::memory_order_relaxed);
                publish_day(from_day, day, day_commit, day_receipts);
                // Control messages are intentionally checked at the day
                // barrier as well as the outer loop.  A long catch-up batch
                // must yield promptly to SAVE/PAUSE/STOP instead of spending
                // the whole debt budget before servicing the request.
                if (_save_requested.load(std::memory_order_acquire) ||
                    _paused.load(std::memory_order_acquire) ||
                    _stop_requested.load(std::memory_order_acquire)) {
                    break;
                }
            }
        }
        if (_state.load(std::memory_order_acquire) != RuntimeWorkerState::FAULTED) {
            _state.store(RuntimeWorkerState::STOPPED, std::memory_order_release);
        }
    } catch (...) {
        set_fault("unhandled_worker_exception");
    }
}

RuntimeThreadReport NativeSimulationHost::report() const {
    RuntimeThreadReport out;
    out.state = _state.load(std::memory_order_acquire);
    out.mode = _mode.load(std::memory_order_acquire);
    out.graph_coverage_complete = _graph_coverage_complete.load(std::memory_order_acquire);
    out.authority_ready = _authority_ready.load(std::memory_order_acquire);
    out.required_domain_mask = RUNTIME_ALL_DOMAIN_MASK;
    out.implemented_domain_mask = implemented_domain_mask();
    out.missing_domain_mask = out.required_domain_mask & ~out.implemented_domain_mask;
    const char *coverage = out.authority_ready ? "complete" : "partial";
    size_t coverage_index = 0;
    for (; coverage_index + 1 < sizeof(out.graph_coverage_state) &&
            coverage[coverage_index] != '\0'; ++coverage_index) {
        out.graph_coverage_state[coverage_index] = coverage[coverage_index];
    }
    out.graph_coverage_state[coverage_index] = '\0';
    const char *blocker = out.authority_ready ? "" :
        (out.missing_domain_mask != 0 ? "missing_native_domain_handlers" :
            "runtime_graph_not_ready");
    size_t blocker_index = 0;
    for (; blocker_index + 1 < sizeof(out.coverage_blocker) &&
            blocker[blocker_index] != '\0'; ++blocker_index) {
        out.coverage_blocker[blocker_index] = blocker[blocker_index];
    }
    out.coverage_blocker[blocker_index] = '\0';
    out.interactive = _interactive.load(std::memory_order_acquire);
    out.paused = _paused.load(std::memory_order_acquire);
    out.speed_days_per_second = _speed_days_per_second.load(std::memory_order_acquire);
    out.committed_day = _committed_day.load(std::memory_order_acquire);
    out.generation = _generation.load(std::memory_order_acquire);
    out.command_queue_capacity_exceeded = _command_queue_capacity_exceeded.load(std::memory_order_relaxed);
    out.receipt_queue_capacity_exceeded = _receipt_queue_capacity_exceeded.load(std::memory_order_relaxed);
    out.snapshot_publish_drop_count = _snapshots.publish_drop_count();
    out.snapshot_publish_throttled_count =
        _snapshot_publish_throttled_count.load(std::memory_order_relaxed);
    out.worker_fault_count = _worker_fault_count.load(std::memory_order_relaxed);
    out.completed_days = _completed_days.load(std::memory_order_relaxed);
    out.day_stage_count = _last_day_stage_count.load(std::memory_order_acquire);
    out.day_completed_stage_count = _last_day_completed_stages.load(
        std::memory_order_acquire);
    out.day_work_units = _last_day_work_units.load(std::memory_order_acquire);
    out.pod_completed_domain_mask = _pod_completed_domain_mask.load(std::memory_order_acquire);
    out.pod_completed_stage_count = _pod_completed_stage_count.load(std::memory_order_acquire);
    out.pod_work_units = _pod_work_units.load(std::memory_order_acquire);
    out.pod_intent_count = _pod_intent_count.load(std::memory_order_acquire);
    out.pod_fallback_count = _pod_fallback_count.load(std::memory_order_acquire);
    out.domain_authority_planned_mask =
        _domain_authority_planned_mask.load(std::memory_order_acquire);
    out.domain_authority_committed_mask =
        _domain_authority_committed_mask.load(std::memory_order_acquire);
    out.domain_authority_ack_count =
        _domain_authority_ack_count.load(std::memory_order_acquire);
    out.domain_authority_input_hash =
        _domain_authority_input_hash.load(std::memory_order_acquire);
    out.domain_authority_state_hash =
        _domain_authority_state_hash.load(std::memory_order_acquire);
    out.domain_authority_plan_ms =
        _domain_authority_plan_ms.load(std::memory_order_acquire);
    out.domain_authority_replay_ms =
        _domain_authority_replay_ms.load(std::memory_order_acquire);
    for (size_t i = 0; i + 1 < sizeof(out.domain_authority_fallback_reason); ++i) {
        const char value = _domain_authority_fallback_reason[i].load(
            std::memory_order_acquire);
        out.domain_authority_fallback_reason[i] = value;
        if (value == '\0') break;
    }
    out.domain_authority_fallback_reason[
        sizeof(out.domain_authority_fallback_reason) - 1] = '\0';
    out.domain_stage_fallback_count = _domain_stage_fallback_count.load(
        std::memory_order_acquire);
    for (size_t i = 0; i + 1 < sizeof(out.domain_stage_fallback_reason); ++i) {
        const char value = _domain_stage_fallback_reason[i].load(
            std::memory_order_acquire);
        out.domain_stage_fallback_reason[i] = value;
        if (value == '\0') break;
    }
    out.domain_stage_fallback_reason[
        sizeof(out.domain_stage_fallback_reason) - 1] = '\0';
    out.climate_pod_ready = _climate_pod_ready.load(std::memory_order_acquire);
    out.climate_pod_plan_ms = _climate_pod_plan_ms.load(std::memory_order_acquire);
    out.climate_pod_replay_ms = _climate_pod_replay_ms.load(std::memory_order_acquire);
    out.climate_pod_work_units = _climate_pod_work_units.load(std::memory_order_acquire);
    out.climate_pod_changed_cells = _climate_pod_changed_cells.load(std::memory_order_acquire);
    out.climate_pod_state_hash = _climate_pod_state_hash.load(std::memory_order_acquire);
    out.climate_pod_reference_hash = _climate_pod_reference_hash.load(std::memory_order_acquire);
    out.climate_pod_parity_compared = _climate_pod_parity_compared.load(std::memory_order_acquire);
    out.climate_pod_parity_matched = _climate_pod_parity_matched.load(std::memory_order_acquire);
    out.climate_pod_parity_mismatch_count = _climate_pod_parity_mismatch_count.load(std::memory_order_acquire);
    out.climate_parity_day = _climate_parity_day.load(std::memory_order_acquire);
    out.climate_parity_stage = _climate_parity_stage.load(std::memory_order_acquire);
    out.climate_parity_cell = _climate_parity_cell.load(std::memory_order_acquire);
    out.climate_parity_input_generation = _climate_parity_input_generation.load(std::memory_order_acquire);
    out.climate_parity_base_generation = _climate_parity_base_generation.load(std::memory_order_acquire);
    out.climate_parity_trace_hash = _climate_parity_trace_hash.load(std::memory_order_acquire);
    for (size_t i = 0; i < _climate_parity_field.size(); ++i) out.climate_parity_field[i] = _climate_parity_field[i].load(std::memory_order_acquire);
    for (size_t i = 0; i < _climate_parity_reference_bits.size(); ++i) out.climate_parity_reference_bits[i] = _climate_parity_reference_bits[i].load(std::memory_order_acquire);
    for (size_t i = 0; i < _climate_parity_worker_bits.size(); ++i) out.climate_parity_worker_bits[i] = _climate_parity_worker_bits[i].load(std::memory_order_acquire);
    for (size_t i = 0; i < _climate_pod_parity_reason.size(); ++i) {
        out.climate_pod_parity_reason[i] =
            _climate_pod_parity_reason[i].load(std::memory_order_acquire);
        if (out.climate_pod_parity_reason[i] == '\0') break;
    }
    for (size_t i = 0; i + 1 < sizeof(out.climate_pod_fallback_reason); ++i) {
        const char value = _climate_pod_fallback_reason[i].load(std::memory_order_acquire);
        out.climate_pod_fallback_reason[i] = value;
        if (value == '\0') break;
    }
    out.climate_pod_fallback_reason[sizeof(out.climate_pod_fallback_reason) - 1] = '\0';
    const uint64_t command_write = _command_enqueue_pos.load(std::memory_order_acquire);
    const uint64_t command_read = _command_dequeue_pos.load(std::memory_order_acquire);
    const uint64_t receipt_write = _receipt_write.load(std::memory_order_acquire);
    const uint64_t receipt_read = _receipt_read.load(std::memory_order_acquire);
    out.command_queue_depth = static_cast<uint32_t>(std::min<uint64_t>(
        command_write - command_read, RUNTIME_COMMAND_QUEUE_CAPACITY));
    out.receipt_queue_depth = static_cast<uint32_t>(std::min<uint64_t>(
        receipt_write - receipt_read, RUNTIME_RECEIPT_QUEUE_CAPACITY));
    out.time_debt_days = _time_debt_days.load(std::memory_order_relaxed);
    out.climate_trace_depth = _climate_trace.depth();
    int64_t trace_front_day = -1;
    if (_climate_trace.front_day(trace_front_day)) {
        out.climate_trace_front_day = trace_front_day;
        const int64_t committed = out.committed_day;
        out.climate_trace_lag_days = committed >= trace_front_day
            ? committed - trace_front_day : 0;
    }
    out.climate_trace_latest_hash = _climate_trace_latest_hash.load(
        std::memory_order_acquire);
    out.climate_trace_capacity_exceeded = _climate_trace.capacity_exceeded();
    out.climate_trace_consumed = _climate_trace_consumed.load(std::memory_order_acquire);
    out.climate_trace_missing = _climate_trace_missing.load(std::memory_order_acquire);
    out.climate_trace_captured = _climate_trace.captured_depth();
    out.climate_trace_reference_ready = _climate_trace.reference_ready_depth();
    out.climate_trace_consumable = _climate_trace.consumable_depth();
    out.climate_trace_reference_rejected = _climate_trace.reference_rejected();
    out.climate_trace_reference_pending = _climate_trace.reference_pending();
    out.state_hash = _state_hash.load(std::memory_order_acquire);
    out.last_commit_produced_at_us = _last_commit_produced_at_us.load(
        std::memory_order_acquire);
    out.last_visual_publish_at_us = _last_visual_publish_us.load(
        std::memory_order_acquire);
    if (out.last_visual_publish_at_us != 0) {
        const uint64_t now = now_us();
        out.snapshot_staleness_ms = now >= out.last_visual_publish_at_us
            ? static_cast<double>(now - out.last_visual_publish_at_us) / 1000.0
            : 0.0;
    }
    out.ui_input_to_feedback_ms = _ui_input_to_feedback_ms.load(
        std::memory_order_acquire);
    out.visual_apply_ms = _visual_apply_ms.load(std::memory_order_acquire);
    out.gpu_upload_ms = _gpu_upload_ms.load(std::memory_order_acquire);
    out.main_wait_on_sim_us = 0;
    out.executor_workers = NativeParallelExecutor::instance().report().active_worker_limit;
    const RuntimeCountryPodDiagnostics country_diag = country_pod_diagnostics();
    out.country_pod_snapshot_generation = country_diag.snapshot_generation;
    out.country_pod_state_hash = country_diag.state_hash;
    out.country_pod_work_units = country_diag.work_units;
    out.country_pod_active_country_count = country_diag.active_country_count;
    out.country_pod_active_index_count = country_diag.active_index_count;
    out.country_pod_pending_checks = country_diag.pending_checks;
    out.country_pod_ack_pending = country_diag.ack_pending != 0;
    runtime_copy_text(out.country_pod_blocker, country_diag.blocker);
    out.environment_generation = _environment_generation.load(std::memory_order_acquire);
    out.environment_day = _environment_day.load(std::memory_order_acquire);
    out.environment_cell_count = _environment_cell_count.load(std::memory_order_acquire);
    out.environment_topology_validated = _environment_topology_validated.load(
        std::memory_order_acquire);
    out.invalid_environment_rejected = _invalid_environment_rejected.load(
        std::memory_order_relaxed);
    out.stale_environment_rejected = _stale_environment_rejected.load(std::memory_order_relaxed);
    for (size_t i = 0; i < sizeof(out.fault_code); ++i) {
        out.fault_code[i] = _fault_code[i].load(std::memory_order_relaxed);
    }
    return out;
}

} // namespace pk

#pragma once

#include "runtime_pod_protocol.h"
#include "runtime_snapshot_ring.h"
#include "runtime_country_pod.h"
#include "runtime_domain_pod.h"
#include "runtime_authoritative_domains.h"
#include "runtime_climate_authority.h"
#include "runtime_climate_trace.h"
#include "runtime_domain_authorities.h"

#include <array>
#include <atomic>
#include <cstddef>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <memory>
#include <vector>

namespace pk {

class NativeSimulationHost {
public:
    NativeSimulationHost();
    ~NativeSimulationHost();

    NativeSimulationHost(const NativeSimulationHost &) = delete;
    NativeSimulationHost &operator=(const NativeSimulationHost &) = delete;

    bool start(RuntimeSimulationMode mode, bool graph_coverage_complete,
               int64_t initial_day, double speed_days_per_second, bool paused);
    // Compatibility overload for existing callers. A boolean coverage hint
    // is always an ACTIVE request; it never proves authority by itself.
    bool start(bool graph_coverage_complete, int64_t initial_day,
               double speed_days_per_second, bool paused) {
        return start(RuntimeSimulationMode::ACTIVE, graph_coverage_complete,
                     initial_day, speed_days_per_second, paused);
    }
    void request_stop();
    void join_for_destruction();
    void set_clock(bool paused, double speed_days_per_second);
    void set_interactive(bool interactive);
    bool publish_environment(const RuntimeEnvironmentSnapshot &snapshot,
                             std::string &error);
    bool publish_climate_reference(int64_t day, uint64_t reference_state_hash,
                                   std::string &error);
    std::shared_ptr<const RuntimeEnvironmentSnapshot> environment_snapshot() const;
    bool publish_country_snapshot(const RuntimeCountryPodSnapshot &snapshot);
    RuntimeCountryPodDiagnostics country_pod_diagnostics() const;

    bool enqueue(RuntimeCommandPacket packet);
    uint64_t allocate_producer_sequence(uint32_t producer_id);
    bool next_command(RuntimeCommandPacket &out) const;
    bool poll_commit(uint64_t after_generation, RuntimeCommit &out);
    bool poll_commit_generation(uint64_t generation, RuntimeCommit &out);
    bool poll_receipt(RuntimeCommandReceipt &out);
    bool request_save(uint64_t request_id);
    std::shared_ptr<const RuntimeSaveBundle> poll_save(uint64_t request_id) const;
    bool restore_bundle(const uint8_t *bytes, size_t size, std::string &error);

    // Main-thread visual instrumentation is an atomic write-only feedback
    // path. It never touches worker-owned stores and never waits for the
    // simulation thread.
    void record_visual_timings(double ui_input_to_feedback_ms,
                               double visual_apply_ms,
                               double gpu_upload_ms);

    RuntimeThreadReport report() const;
    bool stop_requested() const {
        return _stop_requested.load(std::memory_order_acquire);
    }
    // Reports the compile-time POD barrier coverage. This is deliberately
    // independent from the caller's graph_coverage_complete hint.
    static constexpr uint32_t implemented_domain_mask() {
        // COMMIT is the only complete handler until the gameplay domains are
        // moved behind their own POD adapters.
        return runtime_domain_mask(RuntimeDomainId::COMMIT);
    }
    RuntimeWorkerState state() const {
        return _state.load(std::memory_order_acquire);
    }

private:
    static uint64_t now_us();
    static uint64_t mix_hash(uint64_t value, uint64_t input);
    // A worker publishes STOPPED immediately before returning.  Reusing a
    // host must not make the Godot thread join that already-finished handle;
    // the handle is handed to a detached reaper instead.  Destruction waits
    // for reapers after requesting stop, so the host object remains alive for
    // the last instruction of the old worker.
    bool reap_completed_worker_nonblocking();
    void worker_main();
    RuntimeDayPlan build_day_plan(int64_t day, double speed_scale,
                                  const RuntimeEnvironmentSnapshot *environment) const;
    RuntimeDayCommit execute_day_plan(RuntimeDayPlan &plan);
    bool pop_command(RuntimeCommandPacket &out);
    bool push_receipt(const RuntimeCommandReceipt &receipt);
    void publish_day(int64_t from_day, int64_t day,
                     const RuntimeDayCommit &day_commit,
                     const std::vector<RuntimeCommandReceipt> &day_receipts);
    void set_fault(const char *code);
    void build_save_bundle(uint64_t request_id,
                           const std::vector<RuntimeCommandPacket> &pending_commands);

    struct CommandQueueSlot {
        std::atomic<uint64_t> sequence{0};
        RuntimeCommandPacket packet{};
    };

    std::atomic<RuntimeWorkerState> _state{RuntimeWorkerState::STOPPED};
    std::atomic<RuntimeSimulationMode> _mode{RuntimeSimulationMode::OFF};
    std::atomic<bool> _stop_requested{false};
    std::atomic<bool> _paused{true};
    std::atomic<bool> _interactive{false};
    std::atomic<double> _speed_days_per_second{0.0};
    std::atomic<bool> _graph_coverage_complete{false};
    std::atomic<bool> _authority_ready{false};
    std::atomic<int64_t> _committed_day{0};
    std::atomic<uint64_t> _generation{0};
    // Lightweight commit header retained independently from the visual ring.
    // If all three visual buffers are READING, the worker drops only visual
    // intents while the main thread can still observe the authoritative day
    // commit and its hash.
    std::atomic<int64_t> _latest_from_day{0};
    std::atomic<int64_t> _latest_committed_day{0};
    std::atomic<uint64_t> _latest_produced_at_us{0};
    std::atomic<uint32_t> _latest_dirty_families{0};
    std::atomic<uint32_t> _latest_receipt_count{0};
    std::atomic<uint64_t> _last_visual_publish_us{0};
    std::atomic<uint64_t> _snapshot_publish_throttled_count{0};
    std::atomic<uint64_t> _last_commit_produced_at_us{0};
    std::array<std::atomic<uint64_t>, RUNTIME_DIRTY_FAMILY_COUNT>
        _dirty_family_generations{};
    std::atomic<double> _ui_input_to_feedback_ms{0.0};
    std::atomic<double> _visual_apply_ms{0.0};
    std::atomic<double> _gpu_upload_ms{0.0};
    // Bounded MPMC queue.  The per-slot sequence protocol lets multiple UI
    // producers reserve distinct slots without a mutex or a blocking retry.
    std::atomic<uint64_t> _command_enqueue_pos{0};
    std::atomic<uint64_t> _command_dequeue_pos{0};
    std::array<CommandQueueSlot, RUNTIME_COMMAND_QUEUE_CAPACITY> _command_slots{};
    std::array<std::atomic<uint64_t>, 256> _producer_sequences{};
    std::atomic<uint64_t> _fallback_producer_sequence{0};
    std::atomic<uint64_t> _receipt_write{0};
    std::atomic<uint64_t> _receipt_read{0};
    std::array<RuntimeCommandReceipt, RUNTIME_RECEIPT_QUEUE_CAPACITY> _receipts{};

    mutable std::mutex _control_mutex;
    std::condition_variable _control_cv;
    std::atomic<uint32_t> _reaper_count{0};
    std::thread _worker;
    RuntimeSnapshotRing _snapshots;
    std::shared_ptr<const RuntimeEnvironmentSnapshot> _environment_snapshot;
    std::shared_ptr<const RuntimeCountryPodSnapshot> _country_snapshot;
    mutable std::shared_ptr<const RuntimeCountryPodDiagnostics> _country_pod_diagnostics;
    std::atomic<uint64_t> _environment_generation{0};
    std::atomic<int64_t> _environment_day{0};
    std::atomic<uint32_t> _environment_cell_count{0};
    std::atomic<bool> _environment_topology_validated{false};
    std::atomic<uint64_t> _invalid_environment_rejected{0};
    std::atomic<uint64_t> _stale_environment_rejected{0};
    RuntimeClimateTrace _climate_trace;
    std::atomic<uint64_t> _climate_trace_latest_hash{0};
    std::atomic<uint64_t> _climate_trace_consumed{0};
    std::atomic<uint64_t> _climate_trace_missing{0};
    // Incremented whenever the main thread releases a reference-backed trace
    // frame. The worker waits on this value at the day barrier, so a missing
    // reference never degenerates into a fixed-interval polling loop.
    std::atomic<uint64_t> _climate_trace_signal{0};

    std::atomic<bool> _save_requested{false};
    std::atomic<uint64_t> _save_request_id{0};
    // A published bundle is consumed exactly once by the facade.  Keeping the
    // acknowledgement separate from _save_request_id prevents a completed
    // request from being returned forever by repeated UI polling.
    mutable std::atomic<uint64_t> _save_consumed_request_id{0};
    std::shared_ptr<const RuntimeSaveBundle> _save_bundle;
    RuntimeSaveBundle _pending_restore_bundle;
    bool _has_pending_restore = false;
    // Filled by the main-thread restore boundary before the worker starts;
    // consumed exactly once at worker entry, then owned by the worker-local
    // pending command vector.
    std::vector<RuntimeCommandPacket> _worker_initial_pending_commands;

    std::atomic<uint64_t> _command_queue_capacity_exceeded{0};
    std::atomic<uint64_t> _receipt_queue_capacity_exceeded{0};
    std::atomic<uint64_t> _worker_fault_count{0};
    std::atomic<uint64_t> _completed_days{0};
    std::atomic<uint32_t> _last_day_stage_count{0};
    std::atomic<uint32_t> _last_day_completed_stages{0};
    std::atomic<uint64_t> _last_day_work_units{0};
    std::atomic<uint32_t> _pod_completed_domain_mask{0};
    std::atomic<uint32_t> _pod_completed_stage_count{0};
    std::atomic<uint64_t> _pod_work_units{0};
    std::atomic<uint32_t> _pod_intent_count{0};
    std::atomic<uint32_t> _pod_fallback_count{0};
    // Consolidated SHADOW domain runner diagnostics. These values describe a
    // worker-only plan/replay transaction and never unlock ACTIVE.
    std::atomic<uint32_t> _domain_authority_planned_mask{0};
    std::atomic<uint32_t> _domain_authority_committed_mask{0};
    std::atomic<uint32_t> _domain_authority_ack_count{0};
    std::atomic<uint64_t> _domain_authority_input_hash{0};
    std::atomic<uint64_t> _domain_authority_state_hash{0};
    std::atomic<double> _domain_authority_plan_ms{0.0};
    std::atomic<double> _domain_authority_replay_ms{0.0};
    std::array<std::atomic<char>, 64> _domain_authority_fallback_reason{};
    std::atomic<uint32_t> _domain_stage_fallback_count{0};
    std::array<std::atomic<char>, 64> _domain_stage_fallback_reason{};
    std::atomic<bool> _climate_pod_ready{false};
    std::atomic<double> _climate_pod_plan_ms{0.0};
    std::atomic<double> _climate_pod_replay_ms{0.0};
    std::atomic<uint64_t> _climate_pod_work_units{0};
    std::atomic<uint32_t> _climate_pod_changed_cells{0};
    std::atomic<uint64_t> _climate_pod_state_hash{0};
    std::atomic<uint64_t> _climate_pod_reference_hash{0};
    std::atomic<bool> _climate_pod_parity_compared{false};
    std::atomic<bool> _climate_pod_parity_matched{false};
    std::atomic<uint64_t> _climate_pod_parity_mismatch_count{0};
    std::array<std::atomic<char>, 64> _climate_pod_parity_reason{};
    std::atomic<int64_t> _climate_parity_day{-1};
    std::atomic<uint16_t> _climate_parity_stage{0};
    std::atomic<uint32_t> _climate_parity_cell{0};
    std::atomic<uint64_t> _climate_parity_input_generation{0};
    std::atomic<uint64_t> _climate_parity_base_generation{0};
    std::atomic<uint64_t> _climate_parity_trace_hash{0};
    std::array<std::atomic<char>, 48> _climate_parity_field{};
    std::array<std::atomic<char>, 24> _climate_parity_reference_bits{};
    std::array<std::atomic<char>, 24> _climate_parity_worker_bits{};
    std::array<std::atomic<char>, 64> _climate_pod_fallback_reason{};
    std::atomic<double> _time_debt_days{0.0};
    std::array<std::atomic<char>, 64> _fault_code{};
    std::atomic<uint64_t> _state_hash{1469598103934665603ull};
    RuntimeDomainPodPipeline _pod_pipeline;
    // Phase-C migration aggregate.  It is reset and owned exclusively by the
    // worker host; individual domains are enabled only after parity gates.
    RuntimeAuthoritativeDomainStores _authoritative_domains;
    RuntimeDomainAuthorityRunner _domain_authority_runner;
    RuntimeClimateAuthority _climate_authority;
    // Reused worker-local output arenas; no per-day heap growth in the hot
    // loop. They are never exposed to Godot or another thread.
    std::vector<RuntimeVisualIntent> _pod_visual_intents;
    std::vector<RuntimeCommandReceipt> _pod_receipts;
};

} // namespace pk

#pragma once

#include "runtime_pod_protocol.h"
#include "runtime_snapshot_ring.h"
#include "runtime_country_pod.h"
#include "country_core.h"
#include "runtime_domain_pod.h"
#include "runtime_authoritative_domains.h"
#include "runtime_climate_authority.h"
#include "runtime_climate_trace.h"
#include "runtime_climate_parity.h"
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

    // `requested_authority_mask` names the domains this worker is asked to own
    // in ACTIVE. It must be a subset of implemented_domain_mask(); requesting a
    // domain with no POD handler is rejected. The default asks for everything,
    // which is the pre-per-domain behaviour.
    bool start(RuntimeSimulationMode mode, bool graph_coverage_complete,
               int64_t initial_day, double speed_days_per_second, bool paused,
               uint32_t requested_authority_mask = RUNTIME_ALL_DOMAIN_MASK);
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
    // Measurement mode: on a Climate parity mismatch, adopt the production
    // reference for that day instead of discarding the plan. It never makes the
    // worker authoritative; it only stops the first divergent day from blocking
    // every later day, so a multi-day divergence matrix becomes measurable.
    void set_climate_parity_forcing(bool enabled) {
        _climate_parity_forcing.store(enabled, std::memory_order_release);
    }
    bool climate_parity_forcing() const {
        return _climate_parity_forcing.load(std::memory_order_acquire);
    }
    bool publish_environment(const RuntimeEnvironmentSnapshot &snapshot,
                             std::string &error);
    // publish 描述这一天生产 Climate 各段的真实执行情况（跑没跑、用的什么输入），
    // 全部字段可选；见 RuntimeClimateReferencePublish。
    bool publish_climate_reference(
            int64_t day, uint64_t reference_state_hash, std::string &error,
            RuntimeClimateReferencePublish publish = {});
    std::shared_ptr<const RuntimeEnvironmentSnapshot> environment_snapshot() const;
    bool publish_country_snapshot(const RuntimeCountryPodSnapshot &snapshot);
    bool publish_country_checkpoint(const CountryCoreCheckpoint &checkpoint,
                                    std::string &error);
    bool pending_country_checkpoint(CountryCoreCheckpoint &out,
                                    std::string &error) const;
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
        // Which domains have a real POD handler -- NOT which ones are currently
        // authoritative. Those are three different masks and conflating them
        // misreads the whole migration state:
        //   implemented (here)        compile-time; a domain may be listed and
        //                             still run in SHADOW only.
        //   requested_authority_mask  per-session, from the start() caller; must
        //                             be a subset of this one.
        //   completed_domain_mask     per-day report of what actually ran.
        // Climate ships ACTIVE-authoritative in production as of 2026-09-08
        // (runtime_climate_authority_enabled defaults true, which makes
        // world_runtime_host.gd request 0x802). Promotion is per-domain, so the
        // remaining gameplay domains do not block it; only whole-graph ACTIVE
        // (start() without an explicit mask) still requires all of 0xFFF.
        return runtime_domain_mask(RuntimeDomainId::COMMIT)
            | runtime_domain_mask(RuntimeDomainId::CLIMATE);
    }
    RuntimeWorkerState state() const {
        return _state.load(std::memory_order_acquire);
    }
    // Domains this worker has proven at a barrier and now owns. Zero means the
    // main thread still owns every domain. Read by the schedule gate, so it is
    // published only after a commit whose completed_domain_mask covers the
    // request.
    uint32_t authoritative_domain_mask() const {
        return _authoritative_domain_mask.load(std::memory_order_acquire);
    }
    // Main-thread write-back boundary for ACTIVE Climate. Acquire, copy the
    // fields out, release. Non-blocking: returns false when the worker has not
    // committed a newer day.
    bool try_acquire_climate_writeback(uint64_t after_generation,
                                       uint32_t &slot) {
        return _climate_writeback.try_acquire_latest(after_generation, slot);
    }
    const RuntimeClimateSnapshot &climate_writeback_buffer(uint32_t slot) const {
        return _climate_writeback.read_buffer(slot);
    }
    void release_climate_writeback(uint32_t slot) {
        _climate_writeback.release(slot);
    }
    uint64_t climate_writeback_drop_count() const {
        return _climate_writeback.publish_drop_count();
    }
    // Whether a given domain may be suppressed on the main thread this frame.
    bool domain_is_worker_authoritative(RuntimeDomainId domain) const {
        return (authoritative_domain_mask() & runtime_domain_mask(domain)) != 0u;
    }

    // Snapshot of one field's cumulative divergence. Read on the main thread
    // while the worker keeps writing, so the counters are individually atomic
    // and a caller must not read cross-field invariants into them.
    struct ClimateParityFieldStatus {
        uint64_t diverged_days = 0;
        uint64_t compared_days = 0;
        uint64_t diverged_cells = 0;
        // Cells whose difference exceeds the field's tolerance band. For a
        // BITWISE field this equals diverged_cells; for a banded field it is
        // the subset that still needs explaining.
        uint64_t out_of_band_cells = 0;
        uint64_t out_of_band_days = 0;
        int64_t first_diverged_day = -1;
        int64_t first_out_of_band_day = -1;
        uint32_t first_cell = 0;
        uint32_t last_diverged_cells = 0;
        uint32_t last_out_of_band_cells = 0;
        double max_abs_delta = 0.0;
        double max_out_of_band_delta = 0.0;
        char first_reference_bits[24]{};
        char first_worker_bits[24]{};
    };
    ClimateParityFieldStatus climate_parity_field_status(size_t index) const;
    uint64_t climate_parity_forced_days() const {
        return _climate_parity_forced_days.load(std::memory_order_acquire);
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
    // Publishes the first diverging Climate field/cell into the report slots.
    // These slots existed in the ABI but nothing ever wrote them, so a parity
    // failure could only be observed as two unequal hashes.
    void publish_climate_parity_divergence(const RuntimeClimateParityReport &diff);
    void clear_climate_parity_divergence();
    // Folds one day's full per-field comparison into the cumulative stats.
    void accumulate_climate_parity_fields(
            int64_t day, const RuntimeClimateStore &reference,
            const RuntimeClimateStore &worker);
    void reset_climate_parity_fields();
    void build_save_bundle(uint64_t request_id,
                           const std::vector<RuntimeCommandPacket> &pending_commands);

    struct CommandQueueSlot {
        std::atomic<uint64_t> sequence{0};
        RuntimeCommandPacket packet{};
    };

    struct ClimateParityFieldAccumulator {
        std::atomic<uint64_t> diverged_days{0};
        std::atomic<uint64_t> compared_days{0};
        std::atomic<uint64_t> diverged_cells{0};
        std::atomic<uint64_t> out_of_band_cells{0};
        std::atomic<uint64_t> out_of_band_days{0};
        std::atomic<int64_t> first_diverged_day{-1};
        std::atomic<int64_t> first_out_of_band_day{-1};
        std::atomic<uint32_t> first_cell{0};
        std::atomic<uint32_t> last_diverged_cells{0};
        std::atomic<uint32_t> last_out_of_band_cells{0};
        std::atomic<double> max_abs_delta{0.0};
        std::atomic<double> max_out_of_band_delta{0.0};
        std::array<std::atomic<char>, 24> first_reference_bits{};
        std::array<std::atomic<char>, 24> first_worker_bits{};
    };

    std::atomic<RuntimeWorkerState> _state{RuntimeWorkerState::STOPPED};
    std::atomic<RuntimeSimulationMode> _mode{RuntimeSimulationMode::OFF};
    std::atomic<bool> _stop_requested{false};
    std::atomic<bool> _paused{true};
    std::atomic<bool> _interactive{false};
    std::atomic<double> _speed_days_per_second{0.0};
    std::atomic<bool> _graph_coverage_complete{false};
    std::atomic<bool> _authority_ready{false};
    std::atomic<uint32_t> _requested_authority_mask{0};
    std::atomic<uint32_t> _authoritative_domain_mask{0};
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
    std::shared_ptr<const CountryCoreCheckpoint> _country_checkpoint;
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
    // Per-stage worker cost, indexed by RuntimeClimateStage. Published as
    // independent relaxed atomics like the rest of the diagnostic scalars: the
    // reader is a diagnostic table, so a torn row across two stages is
    // acceptable, and a lock here would sit on the worker's day boundary.
    std::array<std::atomic<double>, static_cast<size_t>(
        pk_async_climate::CLIMATE_STAGE_SLOT_COUNT)> _climate_stage_ms{};
    std::array<std::atomic<uint64_t>, static_cast<size_t>(
        pk_async_climate::CLIMATE_STAGE_SLOT_COUNT)> _climate_stage_work{};
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
    // Cumulative per-field divergence, indexed by the canonical parity table.
    // The first-difference slots above name one field per day; a migration plan
    // needs to know how far *every* field is from parity, which is what this
    // accumulates. Fixed size so the worker loop never allocates.
    std::array<ClimateParityFieldAccumulator, RUNTIME_CLIMATE_PARITY_MAX_FIELDS>
        _climate_parity_field_stats{};
    std::atomic<bool> _climate_parity_forcing{false};
    std::atomic<uint64_t> _climate_parity_forced_days{0};
    std::array<std::atomic<char>, 64> _climate_pod_fallback_reason{};
    // 1 << RuntimeClimateStage。见 RuntimeThreadReport::climate_production_stage_mask。
    std::atomic<int32_t> _climate_production_stage_mask{0};
    std::atomic<int32_t> _climate_worker_stage_mask{0};
    std::atomic<double> _time_debt_days{0.0};
    std::array<std::atomic<char>, 64> _fault_code{};
    std::atomic<uint64_t> _state_hash{1469598103934665603ull};
    RuntimeDomainPodPipeline _pod_pipeline;
    // Phase-C migration aggregate.  It is reset and owned exclusively by the
    // worker host; individual domains are enabled only after parity gates.
    RuntimeAuthoritativeDomainStores _authoritative_domains;
    RuntimeDomainAuthorityRunner _domain_authority_runner;
    RuntimeClimateAuthority _climate_authority;
    RuntimeClimateWritebackRing _climate_writeback;
    std::atomic<uint64_t> _climate_writeback_sequence{0};
    // Last Climate day handed to the main thread. Guards against republishing
    // an unchanged store on days the worker clock ran ahead of the environment.
    std::atomic<int64_t> _climate_writeback_last_day{-1};
    // Main-thread-readable mirror of the Climate store's committed day. Under
    // authority this, not `_committed_day`, is the watermark an incoming
    // environment must clear: the worker clock advances on its own and would
    // otherwise reject the very input Climate is waiting for.
    std::atomic<int64_t> _climate_committed_day{-1};
    // Reused worker-local output arenas; no per-day heap growth in the hot
    // loop. They are never exposed to Godot or another thread.
    std::vector<RuntimeVisualIntent> _pod_visual_intents;
    std::vector<RuntimeCommandReceipt> _pod_receipts;
};

} // namespace pk

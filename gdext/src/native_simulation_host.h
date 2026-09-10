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
#include "runtime_events_authority.h"
#include "runtime_modifier_pod.h"
#include "runtime_effect_pod.h"
#include "runtime_ideology_pod.h"

#include <array>
#include <atomic>
#include <cstddef>
#include <condition_variable>
#include <cstdint>
#include <mutex>
#include <string>
#include <thread>
#include <memory>
#include <map>
#include <deque>
#include <unordered_map>
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
    bool publish_country_catalog(const RuntimeCountryPodCatalog &catalog,
                                 std::string &error);
    bool poll_country_worker_intent(CountryPeerIntent &out);
    bool submit_country_worker_result(const CountryPeerResult &result,
                                      std::string &error);
    bool poll_country_economy_asset_request(
            RuntimeEconomyAssetRequest &out);
    bool submit_country_economy_asset_result(
            const RuntimeEconomyAssetResult &result, std::string &error);
    RuntimeEconomyAssetProtocolStatus
    country_economy_asset_protocol_status() const;
    bool country_economy_asset_protocol_self_test(std::string &error) const;
    RuntimeCountryReadView country_worker_read_view(
            uint64_t after_generation = 0) const;
    struct CountryWorkerProtocolStatus {
        uint32_t protocol_version = COUNTRY_PEER_PROTOCOL_VERSION;
        bool configured = false;
        bool plan_active = false;
        bool waiting_for_peer = false;
        uint32_t pending_intents = 0;
        uint32_t queued_intents = 0;
        uint32_t result_count = 0;
        uint32_t rejected_results = 0;
        uint32_t rejected_intents = 0;
        bool has_unreported_rejection = false;
        int64_t retry_day = -1;
        uint64_t rejected_request_id = 0;
        uint64_t session_epoch = 0;
        uint64_t country_generation = 0;
        int64_t day = -1;
        uint32_t continuation_index = 0;
        uint64_t boundary_id = 0;
        uint64_t last_admitted_submit_order = 0;
        uint64_t expected_base_generation = 0;
        uint64_t catalog_hash = 0;
        char last_reason[64]{};
    };
    CountryWorkerProtocolStatus country_worker_protocol_status() const;
    bool publish_country_checkpoint(const CountryCoreCheckpoint &checkpoint,
                                    std::string &error);
    bool pending_country_checkpoint(CountryCoreCheckpoint &out,
                                    std::string &error) const;
    RuntimeCountryPodDiagnostics country_pod_diagnostics() const;
    bool configure_trigger_pod(const RuntimeTriggerPodCatalog &catalog,
                               std::string &error);
    bool queue_trigger_pod_command(const RuntimeTriggerCommand &command,
                                   std::string &error);
    RuntimeTriggerPodDiagnostics trigger_pod_diagnostics() const;
    bool set_trigger_reference_frame(int64_t day, uint64_t input_hash,
                                     uint64_t state_hash, uint64_t effect_hash,
                                     std::string &error);
    const RuntimeTriggerPodCatalog &trigger_pod_catalog() const;
    bool encode_trigger_pod_save(std::vector<uint8_t> &bytes,
                                 std::string &error) const;
    bool restore_trigger_pod_save(const uint8_t *bytes, size_t size,
                                  std::string &error);
    bool configure_modifier_pod(const RuntimeModifierPodCatalog &catalog,
                                std::string &error);
    bool encode_modifier_pod_save(std::vector<uint8_t> &bytes,
                                  std::string &error) const;
    bool restore_modifier_pod_save(const uint8_t *bytes, size_t size,
                                   std::string &error);
    bool try_acquire_modifier_snapshot(uint64_t after_generation,
                                        uint32_t &slot);
    const RuntimeModifierPodSnapshot &modifier_snapshot_buffer(uint32_t slot) const;
    void release_modifier_snapshot(uint32_t slot);
    bool modifier_pod_self_test(std::string *error = nullptr) const;
    uint64_t modifier_pod_catalog_hash() const {
        return _modifier_pod_configured ? _modifier_pod_catalog.catalog_hash : 0;
    }
    void set_events_probe_enabled(bool enabled) {
        _events_probe_enabled.store(enabled, std::memory_order_release);
    }
    bool events_probe_enabled() const {
        return _events_probe_enabled.load(std::memory_order_acquire);
    }
    bool try_acquire_events_snapshot(uint64_t after_generation, uint32_t &slot) {
        return _events_snapshots.try_acquire_latest(after_generation, slot);
    }
    const RuntimeEventsSnapshot &events_snapshot_buffer(uint32_t slot) const {
        return _events_snapshots.read_buffer(slot);
    }
    void release_events_snapshot(uint32_t slot) { _events_snapshots.release(slot); }
    uint64_t events_snapshot_drop_count() const {
        return _events_snapshots.publish_drop_count();
    }
    bool events_authority_self_test() const;
    bool configure_effect_pod(const RuntimeEffectPodCatalog &catalog,
                              std::string &error);
    bool encode_effect_pod_save(std::vector<uint8_t> &bytes,
                                std::string &error) const;
    bool restore_effect_pod_save(const uint8_t *bytes, size_t size,
                                 std::string &error);
    RuntimeEffectPodReport effect_pod_report() const {
        return _effect_pod_authority.report();
    }
    bool effect_pod_self_test(std::string *error = nullptr) const;
    bool configure_ideology_pod(const RuntimeIdeologyPodCatalog &catalog,
                                std::string &error);
    bool publish_ideology_opinion_snapshot(
        const RuntimeIdeologyOpinionSnapshot &snapshot, std::string &error);
    bool queue_ideology_pod_command(const RuntimeIdeologyPodCommand &command,
                                    std::string &error);
    bool poll_ideology_pod_intent(RuntimeDomainIntent &intent);
    bool submit_ideology_pod_ack(const RuntimeDomainAck &ack,
                                 std::string &error);
    std::shared_ptr<const RuntimeIdeologyPodSnapshot> ideology_pod_snapshot() const;
    bool encode_ideology_pod_save(std::vector<uint8_t> &bytes,
                                  std::string &error) const;
    bool restore_ideology_pod_save(const uint8_t *bytes, size_t size,
                                   std::string &error);
    bool ideology_pod_self_test(std::string *error = nullptr) const;

    bool enqueue(RuntimeCommandPacket packet);
    // Country facade batches are a semantic admission unit. The Host checks
    // capacity before publishing any packet and assigns submit_order in the
    // same critical section, so transport chunking cannot split a business
    // batch or change its tie-break order.
    bool enqueue_batch(std::vector<RuntimeCommandPacket> packets);
    bool enqueue_modifier_shadow(RuntimeCommandPacket packet);
    uint64_t allocate_command_request_id();
    uint64_t allocate_producer_sequence(uint32_t producer_id);
    bool next_command(RuntimeCommandPacket &out) const;
    bool poll_commit(uint64_t after_generation, RuntimeCommit &out);
    bool poll_commit_generation(uint64_t generation, RuntimeCommit &out);
    bool poll_receipt(RuntimeCommandReceipt &out);
    bool poll_country_command_receipts(
            uint64_t after_request_id, uint32_t limit,
            std::vector<CountryCommandReceipt> &out);
    bool country_command_receipt_self_test(std::string &error) const;
    bool country_peer_rejection_self_test(std::string &error) const;
    bool publish_country_economy_asset_requests(
            const std::vector<RuntimeEconomyAssetRequest> &requests,
            std::string &error);
    void discard_country_economy_asset_requests(
            const std::vector<uint64_t> &request_ids) noexcept;
    void set_country_economy_asset_protocol_error_locked(
            RuntimeEconomyAssetProtocolError code, uint64_t transaction_id,
            uint64_t request_id, const char *reason) noexcept;
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
    RuntimeDayCommit execute_day_plan(
            RuntimeDayPlan &plan,
            const std::vector<RuntimeCommandPacket> &day_commands,
            std::vector<RuntimeCommandReceipt> &day_receipts,
            uint64_t admitted_submit_order);
    bool execute_country_worker_stage(
            int64_t day, uint64_t input_generation,
            const std::vector<RuntimeCommandPacket> &day_commands,
            RuntimeDayCommit &commit, std::string &error,
            uint64_t admitted_submit_order);
    bool publish_country_worker_snapshot(uint32_t dirty_families,
                                         std::string &error);
    bool execute_ideology_worker_stage(int64_t day,
                                       RuntimeDayCommit &commit,
                                       std::string &error);
    void publish_country_command_terminals(
            const std::vector<RuntimeCountryCommand> &commands,
            CountryCommandReceiptCode code, uint64_t generation,
            const char *reason);
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
    mutable std::mutex _command_enqueue_mutex;
    // Monotonic admission order for the shared command boundary. This is
    // independent of producer-local sequence numbers and is Country's final
    // same-day tie-breaker.
    std::atomic<uint64_t> _command_submit_order{0};
    std::atomic<uint64_t> _command_request_id{0};
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
    std::shared_ptr<const RuntimeCountryPodSnapshot> _country_committed_snapshot;
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
    // Country peer transport is a bounded cooperative bridge. The worker owns
    // the POD authority and plan; the main thread only moves typed values in
    // and out of these queues and never touches the authority itself.
    mutable std::mutex _country_transport_mutex;
    RuntimeCountryPodAuthority _country_pod_authority;
    RuntimeCountryPodCatalog _country_pod_catalog;
    std::atomic<bool> _country_pod_configured{false};
    std::atomic<bool> _country_pod_plan_active{false};
    CountryPeerProtocolStatus _country_worker_protocol{};
    RuntimeCountryPodPlan _country_pod_plan;
    std::deque<uint64_t> _country_worker_intent_queue;
    std::unordered_map<uint64_t, CountryPeerIntent> _country_worker_intents;
    std::unordered_map<uint64_t, CountryPeerResult> _country_worker_results;
    std::unordered_map<uint64_t, CountryPeerResult> _country_worker_terminal_results;
    // Country -> Economy is a separate bounded transport.  Requests remain
    // addressable after polling so a delayed/duplicate result can be checked
    // against the original transaction identity; only terminal results are
    // retained in the terminal cache after the worker consumes the request.
    std::deque<uint64_t> _country_economy_asset_request_queue;
    std::unordered_map<uint64_t, RuntimeEconomyAssetRequest>
        _country_economy_asset_requests;
    std::unordered_map<uint64_t, RuntimeEconomyAssetResult>
        _country_economy_asset_results;
    std::unordered_map<uint64_t, RuntimeEconomyAssetResult>
        _country_economy_asset_terminal_results;
    RuntimeEconomyAssetProtocolStatus _country_economy_asset_protocol{};
    // Country command lifecycle is separate from the legacy generic receipt
    // queue. The generic queue reports transport/preflight admission for all
    // domains; this ordered map carries Country's typed terminal state and is
    // drained by a request-id cursor so a terminal result cannot be confused
    // with an admission acknowledgement.
    std::map<uint64_t, CountryCommandReceipt> _country_command_terminals;
    // Complete Host-side request lifecycle. The terminal map is only the
    // cursor-visible projection; this map also retains Accepted requests so a
    // save can prove that every restored Country pending packet is admissible.
    std::map<uint64_t, CountryCommandReceipt> _country_command_states;
    std::atomic<uint64_t> _country_peer_signal{0};
    uint64_t _country_worker_session_epoch = 1;
    uint64_t _country_worker_country_generation = 0;
    int64_t _country_worker_day = -1;
    uint32_t _country_worker_continuation_index = 0;
    CountryBoundarySeal _country_worker_seal{};
    uint64_t _country_read_view_generation = 0;
    uint64_t _country_read_view_patch_base_generation = 0;
    uint32_t _country_read_view_dirty_families = 0;
    std::vector<int32_t> _country_read_view_changed_cells;
    std::vector<int32_t> _country_read_view_changed_owners;
    std::atomic<bool> _events_probe_enabled{false};

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
    std::vector<RuntimeCommandPacket> _prestart_modifier_commands;

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
    std::atomic<bool> _country_pod_ready{false};
    std::array<std::atomic<char>, 64> _country_pod_fallback_reason{};
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
    RuntimeModifierPodAuthority _modifier_pod_authority;
    RuntimeModifierPodCatalog _modifier_pod_catalog;
    bool _modifier_pod_configured = false;
    RuntimeModifierSnapshotRing _modifier_snapshots;
    std::atomic<bool> _modifier_pod_ready{false};
    std::atomic<double> _modifier_pod_plan_ms{0.0};
    std::atomic<double> _modifier_pod_replay_ms{0.0};
    std::atomic<uint64_t> _modifier_pod_work_units{0};
    std::atomic<uint64_t> _modifier_pod_state_hash{0};
    std::atomic<uint64_t> _modifier_pod_snapshot_generation{0};
    std::atomic<uint32_t> _modifier_pod_ack_count{0};
    std::array<std::atomic<char>, 64> _modifier_pod_fallback_reason{};
    RuntimeEventsAuthority _events_authority;
    RuntimeEventsSnapshotRing _events_snapshots;
    std::atomic<bool> _events_pod_ready{false};
    std::atomic<double> _events_pod_plan_ms{0.0};
    std::atomic<double> _events_pod_replay_ms{0.0};
    std::atomic<uint64_t> _events_pod_state_hash{0};
    std::atomic<uint64_t> _events_pod_snapshot_generation{0};
    std::atomic<uint32_t> _events_pod_event_count{0};
    std::atomic<uint32_t> _events_pod_ack_count{0};
    std::atomic<uint64_t> _events_pod_drop_count{0};
    std::array<std::atomic<char>, 64> _events_pod_fallback_reason{};
    // Events is a diagnostic sidecar. Keep a worker-local watermark so a
    // Climate input-barrier retry cannot advance its generation twice for the
    // same host day.
    int64_t _events_last_processed_day = -1;
    RuntimeEffectPodAuthority _effect_pod_authority;
    RuntimeEffectPodCatalog _effect_pod_catalog;
    bool _effect_pod_configured = false;
    mutable std::mutex _ideology_transport_mutex;
    RuntimeIdeologyPodAuthority _ideology_pod_authority;
    RuntimeIdeologyPodCatalog _ideology_pod_catalog;
    bool _ideology_pod_configured = false;
    std::shared_ptr<const RuntimeIdeologyOpinionSnapshot> _ideology_opinion_snapshot;
    std::shared_ptr<const RuntimeIdeologyPodSnapshot> _ideology_snapshot;
    std::deque<RuntimeIdeologyPodCommand> _ideology_commands;
    std::deque<RuntimeDomainIntent> _ideology_intents;
    std::deque<RuntimeDomainAck> _ideology_acks;
    std::atomic<bool> _ideology_pod_ready{false};
    std::atomic<double> _ideology_pod_plan_ms{0.0};
    std::atomic<double> _ideology_pod_replay_ms{0.0};
    std::atomic<uint64_t> _ideology_pod_state_hash{0};
    std::atomic<uint64_t> _ideology_pod_snapshot_generation{0};
    std::atomic<uint32_t> _ideology_pod_pending_transition_count{0};
    std::atomic<uint32_t> _ideology_pod_intent_count{0};
    std::array<std::atomic<char>, 64> _ideology_pod_fallback_reason{};
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

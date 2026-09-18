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
#include "runtime_economy_pod.h"
#include "economy_graph_kernels.h"

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
#include <unordered_set>
#include <vector>

namespace pk {

class NativeEconomyRuntime;
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
    // worker：ring 内仍有未评估输入（有活可干）。
    bool has_pending_climate_input() const;
    // 主线程 publish：ring 已满，需 wait 腾空位。
    bool environment_ring_full() const;
    size_t environment_ring_pending() const;
    // publish 描述这一天生产 Climate 各段的真实执行情况（跑没跑、用的什么输入），
    // 全部字段可选；见 RuntimeClimateReferencePublish。
    bool publish_climate_reference(
            int64_t day, uint64_t reference_state_hash, std::string &error,
            RuntimeClimateReferencePublish publish = {});
    // 最近一次成功 publish（诊断 / 物理派生）。worker 日计划请用
    // environment_input_for_plan()。
    std::shared_ptr<const RuntimeEnvironmentSnapshot> environment_snapshot() const;
    // FIFO 最旧未消费输入；空则退回 latest。
    std::shared_ptr<const RuntimeEnvironmentSnapshot>
    environment_input_for_plan() const;
    bool publish_country_snapshot(const RuntimeCountryPodSnapshot &snapshot);
    void publish_economy_reference(int64_t day, uint64_t generation,
                                   uint64_t state_hash) noexcept;
    // Per-stage sync reference for SHADOW Economy POD parity tooling. Does not
    // grant ACTIVE authority.
    void publish_economy_stage_reference(uint32_t stage, int64_t day,
                                         uint64_t generation,
                                         uint64_t state_hash,
                                         uint64_t work_units) noexcept;
    bool execute_economy_worker_stage(int64_t day, uint64_t input_generation,
                                      uint32_t cell_count,
                                      uint64_t country_generation,
                                      uint64_t catalog_hash,
                                      std::string &error);
    void attach_economy_stage_ops(
        std::unique_ptr<EconomyGraphStageOps> ops) noexcept;
    // Phase-2.4.1: when true, StageOps are attached with mutate=true (armed for
    // future production handoff). Production ACTIVE still runs compact-slice
    // unless a later slice replaces that loop.
    void set_economy_stage_ops_mutate(bool mutate) noexcept {
        _economy_stage_ops_mutate.store(mutate, std::memory_order_release);
    }
    bool economy_stage_ops_mutate() const noexcept {
        return _economy_stage_ops_mutate.load(std::memory_order_acquire);
    }
    // After a complete ledger capture, optionally promote authority to
    // M6 keeps authority switches explicit. Mirror readiness is diagnostic;
    // it never changes the writer without an epoch-boundary API call.
    void set_economy_auto_pod_active(bool enabled) noexcept {
        _economy_auto_pod_active.store(enabled, std::memory_order_release);
    }
    bool economy_auto_pod_active() const noexcept {
        return _economy_auto_pod_active.load(std::memory_order_acquire);
    }
    // ECP2 dual-write / mid-epoch / authority cutover (E10). Dual-write defaults
    // on; mid-epoch and authority cutover default off until self_test proves RT.
    void set_economy_ecp2_dual_write(bool enabled) noexcept {
        _economy_ecp2_dual_write.store(enabled, std::memory_order_release);
    }
    bool economy_ecp2_dual_write() const noexcept {
        return _economy_ecp2_dual_write.load(std::memory_order_acquire);
    }
    void set_economy_ecp2_mid_epoch_save(bool enabled) noexcept {
        _economy_ecp2_mid_epoch_save.store(enabled, std::memory_order_release);
    }
    bool economy_ecp2_mid_epoch_save() const noexcept {
        return _economy_ecp2_mid_epoch_save.load(std::memory_order_acquire);
    }
    void set_economy_ecp2_authority(bool enabled) noexcept {
        _economy_ecp2_authority.store(enabled, std::memory_order_release);
    }
    bool economy_ecp2_authority() const noexcept {
        return _economy_ecp2_authority.load(std::memory_order_acquire);
    }
    // Phase-2.4.2: production writer selection. STAGE_OPS effective only when
    // soak experiment or soak_parity_ok is armed (P2.4.4.4); default compact.
    void set_economy_stage_ops_soak_experiment(bool enabled) noexcept {
        _economy_stage_ops_soak_experiment.store(enabled,
                                                 std::memory_order_release);
    }
    bool economy_stage_ops_soak_experiment() const noexcept {
        return _economy_stage_ops_soak_experiment.load(
            std::memory_order_acquire);
    }
    void set_economy_stage_ops_soak_parity_ok(bool ok) noexcept {
        _economy_stage_ops_soak_parity_ok.store(ok, std::memory_order_release);
    }
    bool economy_stage_ops_soak_parity_ok() const noexcept {
        return _economy_stage_ops_soak_parity_ok.load(
            std::memory_order_acquire);
    }
    void set_economy_production_writer(EconomyProductionWriter writer) noexcept {
        _economy_production_writer_requested.store(
            static_cast<uint32_t>(writer), std::memory_order_release);
        // Phase-2.4.5: StageOps may be effective once start gates pass (mutate +
        // readiness). Soak experiment / parity latch remain observability.
        _economy_production_writer_effective.store(
            static_cast<uint32_t>(writer), std::memory_order_release);
    }
    EconomyProductionWriter economy_production_writer_requested() const noexcept {
        return static_cast<EconomyProductionWriter>(
            _economy_production_writer_requested.load(std::memory_order_acquire));
    }
    EconomyProductionWriter economy_production_writer_effective() const noexcept {
        return static_cast<EconomyProductionWriter>(
            _economy_production_writer_effective.load(std::memory_order_acquire));
    }
    // Phase-2.4.4.2: one Host pulse of StageOps production orchestration.
    // Requires mutate StageOps + production runtime. Soft-parks on pending_input.
    bool worker_run_stage_ops_slice(int64_t day, uint64_t input_generation,
                                    std::string &error, bool *done = nullptr,
                                    bool *pending_input = nullptr);
    // Prefer set_economy_execution_mode(); this remains for probe-only tests.
    void set_economy_shadow_probe_enabled(bool enabled) {
        _economy_shadow_probe_enabled.store(enabled, std::memory_order_release);
    }
    bool economy_shadow_probe_enabled() const {
        return _economy_shadow_probe_enabled.load(std::memory_order_acquire);
    }
    // Phase-1 execution mode. Default ACTIVE_ONLY (SHADOW StageOps = 0).
    void set_economy_execution_mode(EconomyExecutionMode mode) noexcept;
    EconomyExecutionMode economy_execution_mode() const noexcept {
        return static_cast<EconomyExecutionMode>(
            _economy_execution_mode.load(std::memory_order_acquire));
    }
    bool economy_parity_shadow_enabled() const noexcept {
        return economy_execution_mode() ==
                   EconomyExecutionMode::ACTIVE_WITH_PARITY &&
               economy_shadow_probe_enabled();
    }
    bool economy_worker_production_allowed() const noexcept {
        return economy_execution_mode() != EconomyExecutionMode::LEGACY_ONLY;
    }
    // Phase-2 authority switch. POD_ACTIVE is refused until the committed POD
    // mirror covers the full production ledger (see economy-ledger-migration-status).
    bool switch_economy_authority(RuntimeEconomyAuthorityMode mode,
                                  std::string &error) noexcept;
    // Deterministic release-gate probe for the fault handoff contract. It
    // uses an isolated host and never mutates the live simulation worker.
    bool economy_authority_fault_gate_self_test(std::string &error) const noexcept;
    // One-shot fault injection by domain/stage point name. Armed points trip
    // exactly once when the worker reaches that boundary (plan/reservation/
    // commit/Events/save/restore/authority switch). Returns false when the
    // point name is empty or truncated.
    bool arm_fault_injection(const char *point) noexcept;
    void clear_fault_injection() noexcept;
    bool fault_injection_armed() const noexcept {
        return _fault_injection_armed.load(std::memory_order_acquire);
    }
    uint64_t fault_injection_trip_count() const noexcept {
        return _fault_injection_trip_count.load(std::memory_order_acquire);
    }
    bool economy_worker_is_authoritative() const noexcept {
        return economy_production_runtime_attached() &&
               economy_execution_mode() != EconomyExecutionMode::LEGACY_ONLY &&
               domain_is_worker_authoritative(RuntimeDomainId::ECONOMY);
    }
    RuntimeEconomyAuthorityMode economy_authority_mode() const noexcept {
        return _economy_pod_authority.authority_mode();
    }
    bool economy_legacy_fallback_enabled() const noexcept {
        return economy_execution_mode() == EconomyExecutionMode::LEGACY_ONLY ||
               _economy_pod_authority.authority_mode() ==
                   RuntimeEconomyAuthorityMode::LEGACY_SYNC ||
               _economy_pod_authority.authority_mode() ==
                   RuntimeEconomyAuthorityMode::POD_ACTIVE_WITH_LEGACY_PARITY;
    }
    uint64_t economy_shadow_stage_invocations() const noexcept {
        return _economy_shadow_stage_invocations.load(std::memory_order_acquire);
    }
    uint64_t economy_shadow_stage_cache_hits() const noexcept {
        return _economy_shadow_stage_cache_hits.load(std::memory_order_acquire);
    }
    // ACTIVE production: point at the live NativeEconomyRuntime formula owner.
    // StageOps mutate flag is independent; default attach is mutate=false and
    // production mutations use worker_run_compact_slice.
    void attach_economy_production_runtime(class NativeEconomyRuntime *rt) noexcept;
    NativeEconomyRuntime *economy_production_runtime() const noexcept {
        return _economy_production_runtime;
    }
    bool economy_production_runtime_attached() const noexcept {
        return _economy_production_runtime != nullptr;
    }
    // Phase 4+: POD queue admits opcodes 1..23; commit_pending_commands applies
    // via EconomyPodCommandExecutor. Under POD_ACTIVE, opcodes 1–23 mutate
    // OwnedState first then pull into NativeEconomyRuntime (heavy opcodes
    // delegate apply then mirror). Host verifies hash/shape and recaptures only
    // on mismatch. Phase-5 binds population/market to OwnedState sole SoA.
    // Sync submit_commands remains a separate facade — do not double-submit.
    bool submit_economy_pod_command(const RuntimeEconomyPodCommand &command,
                                    std::string &error);
    bool poll_economy_pod_receipt(RuntimeEconomyPodReceipt &out) noexcept;
    void set_economy_sync_writes_forbidden(bool forbidden) noexcept;
    bool economy_sync_writes_forbidden() const noexcept {
        return _economy_sync_writes_forbidden.load(std::memory_order_acquire);
    }
    bool publish_country_catalog(const RuntimeCountryPodCatalog &catalog,
                                 std::string &error);
    bool country_pod_configured() const {
        return _country_pod_configured.load(std::memory_order_acquire);
    }
    bool publish_country_reference(int64_t day, uint64_t reference_state_hash,
                                   std::string &error,
                                   const RuntimeCountryPodSnapshot *snapshot = nullptr);
    bool mirror_country_peer_result(const CountryPeerResult &result,
                                    std::string &error);
    bool mirror_sync_country_economy_asset(
            const RuntimeEconomyAssetRequest &request,
            const RuntimeEconomyAssetResult &result, std::string &error);
    bool country_shadow_parity_self_test(std::string &error) const;
    bool poll_country_worker_intent(CountryPeerIntent &out);
    bool submit_country_worker_result(const CountryPeerResult &result,
                                      std::string &error);
    bool poll_country_economy_asset_request(
            RuntimeEconomyAssetRequest &out);
    // Economy owns peer-side mutation. Its continuation needs a read-only
    // terminal lookup so it can resume the same request identity without
    // creating a second Country transaction.
    bool country_economy_asset_terminal_result(
            uint64_t request_id, RuntimeEconomyAssetResult &out) const;
    bool submit_country_economy_asset_result(
            const RuntimeEconomyAssetResult &result, std::string &error);
    bool requeue_country_economy_asset_request(uint64_t request_id,
                                               std::string &error);
    RuntimeEconomyAssetProtocolStatus
    country_economy_asset_protocol_status() const;
    bool country_economy_asset_protocol_self_test(std::string &error) const;
    bool enqueue_economy_origin_country_asset(
            RuntimeEconomyAssetRequest request, std::string &error);
    enum class CountryAuthorityOwner : uint8_t { SYNC = 0, WORKER = 1 };
    struct CountryAuthorityHandoffStatus {
        CountryAuthorityOwner owner = CountryAuthorityOwner::SYNC;
        CountryAuthorityOwner prepared_target = CountryAuthorityOwner::SYNC;
        bool prepare_pending = false;
        uint64_t session_epoch = 0;
        char last_reason[64]{};
    };
    bool prepare_country_authority_handoff(CountryAuthorityOwner target,
                                           std::string &error);
    bool abort_country_authority_handoff(std::string &error);
    bool install_country_authority_handoff(std::string &error);
    CountryAuthorityHandoffStatus country_authority_handoff_status() const;
    // D10 unique-writer / sync-slice gate. Independent of
    // authoritative_domain_mask for protocol tests, but production ACTIVE
    // Country also sets this via domain_is_worker_authoritative after D12.
    bool country_authority_owner_is_worker() const {
        return country_authority_handoff_status().owner ==
            CountryAuthorityOwner::WORKER;
    }
    bool country_authority_handoff_prepare_pending() const {
        return country_authority_handoff_status().prepare_pending;
    }
    bool country_authority_handoff_self_test(std::string &error) const;
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
    // H8 ACTIVE write-back boundary. Acquire, apply into the legacy
    // TriggerRuntime facade, release. Non-blocking.
    bool try_acquire_trigger_snapshot(uint64_t after_generation, uint32_t &slot);
    const RuntimeTriggerSnapshot &trigger_snapshot_buffer(uint32_t slot) const;
    void release_trigger_snapshot(uint32_t slot);
    uint64_t trigger_snapshot_drop_count() const {
        return _trigger_snapshots.publish_drop_count();
    }
    // H8 real-ACK transport. Trigger effect intents require a peer ACK before
    // the day commits; the worker Effect stage drains them in-worker when EFFECT
    // is granted in the same session, and this pair is the main-thread protocol
    // path for a TRIGGER-only grant.
    bool poll_trigger_pod_intent(RuntimeDomainIntent &intent);
    bool submit_trigger_pod_ack(const RuntimeDomainAck &ack, std::string &error);
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
    bool try_acquire_effect_snapshot(uint64_t after_generation, uint32_t &slot);
    const RuntimeEffectPodSnapshot &effect_snapshot_buffer(uint32_t slot) const;
    void release_effect_snapshot(uint32_t slot);
    bool try_acquire_ideology_snapshot(uint64_t after_generation, uint32_t &slot);
    const RuntimeIdeologyPodSnapshot &ideology_snapshot_buffer(uint32_t slot) const;
    void release_ideology_snapshot(uint32_t slot);
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
    // F7 host-stage smoke: plan/commit + MODIFIER intent emission + ACK
    // round-trip. Does not grant EFFECT ACTIVE authority.
    bool effect_pod_host_stage_self_test(std::string *error = nullptr);
    // F7 SHADOW transport. Main-thread EffectRuntime remains production
    // authority; these queues only mirror declarative POD-expressible state
    // and expose worker intents/ACKs for diagnostics and Modifier E7.
    bool queue_effect_pod_instance(const RuntimeEffectPodInstanceInput &input,
                                   std::string &error);
    bool queue_effect_pod_metric(int64_t instance_id, uint32_t generation,
                                 int32_t metric_id, int64_t revision,
                                 int64_t value, std::string &error);
    bool queue_effect_pod_remove(int64_t instance_id, uint32_t generation,
                                 std::string &error);
    bool poll_effect_pod_intent(RuntimeDomainIntent &intent);
    bool submit_effect_pod_ack(const RuntimeDomainAck &ack, std::string &error);
    int32_t effect_pod_program_id_for_key(const char *key) const;
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
    // Point lookup for Effect ACK. Cursor polls skip lower Effect terminals
    // once an unrelated Country commit advances the high-water mark.
    bool try_country_command_terminal(
            uint64_t request_id, CountryCommandReceipt &out);
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
        // M5: all twelve domains have a bounded POD handler and participate
        // in the same frozen-input -> continuation -> atomic-COMMIT barrier.
        // This is the implementation capability mask; a session still has to
        // request a subset and prove it at a commit before it is granted.
        // Production requests the complete graph (0xFFF); focused diagnostics
        // may still request a smaller subset. Contract:
        // authoritative & EFFECT => worker is the sole Effect writer; snapshot
        // write-back targets legacy EffectRuntime; only effect_runtime /
        // run_effect_daily is suppressed. IDEOLOGY follows the same shape
        // against NativeIdeologyRuntime, TRIGGER_INPUT against TriggerRuntime.
        // MODIFIER intents ACK in-worker; Ideology's and Trigger's
        // EFFECT-targeted intents ACK in-worker after the Effect stage and
        // through the main-thread pump; other domains use the main-thread intent
        // pump. EVENTS is a worker-authority mirror only: the POD store owns the
        // stage bit, snapshot, and consumer cursor. The legacy
        // GameplayEventBus facade remains available only for explicit recovery
        // and compatibility reads.
        // ECONOMY owns ACTIVE production via attach_economy_production_runtime
        // + worker_run_compact_slice (same NativeEconomyRuntime formula owner).
        // StageOps stay mutate=false for SHADOW POD parity hashes only.
        // Main-thread economy_should_run is suppressed when worker-authoritative
        // AND the production runtime pointer is attached (fail-open to sync
        // otherwise).
        return runtime_domain_mask(RuntimeDomainId::INPUT_CAPTURE)
            | runtime_domain_mask(RuntimeDomainId::CLIMATE)
            | runtime_domain_mask(RuntimeDomainId::COUNTRY)
            | runtime_domain_mask(RuntimeDomainId::TRIGGER_INPUT)
            | runtime_domain_mask(RuntimeDomainId::IDEOLOGY)
            | runtime_domain_mask(RuntimeDomainId::EFFECT)
            | runtime_domain_mask(RuntimeDomainId::MODIFIER)
            | runtime_domain_mask(RuntimeDomainId::GAMEPLAY_EFFECT)
            | runtime_domain_mask(RuntimeDomainId::ECONOMY)
            | runtime_domain_mask(RuntimeDomainId::EVENTS)
            | runtime_domain_mask(RuntimeDomainId::VISUAL)
            | runtime_domain_mask(RuntimeDomainId::COMMIT);
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
    static constexpr size_t ECONOMY_AUTHORITY_SWITCH_LATENCY_SAMPLE_CAPACITY = 256u;
    // Worker-owned event snapshot boundary.  Consumers use this only after
    // EVENTS has been granted; legacy journal polling remains available for
    // explicit fallback/parity sessions.
    bool events_worker_authoritative() const {
        return domain_is_worker_authoritative(RuntimeDomainId::EVENTS);
    }
    // B8 P3：ACTIVE Climate 的主线程等待边界。
    // - after_generation > 0：等到 worker 已评估过该代次（plan 尝试，不要求提交）。
    // - after_generation == 0：等到输入 ring 有空位（可流水线发布下一天）。
    // timeout_ms < 0 表示等到条件满足；>= 0 是一次有界等待切片。
    //
    // 终止条件（故障保护，不是性能超时）：worker 进入 FAULTED/STOPPING/STOPPED、
    // Climate 权威被撤销、或 stop 被请求。
    bool wait_climate_consumed(uint64_t after_generation, int64_t timeout_ms,
                               uint64_t &consumed_generation,
                               std::string &error);
    void note_climate_writeback_input_generation(uint64_t generation) {
        _climate_writeback_input_generation.store(generation,
                                                   std::memory_order_release);
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
            const RuntimeEnvironmentSnapshot *environment,
            const std::vector<RuntimeCommandPacket> &day_commands,
            std::vector<RuntimeCommandReceipt> &day_receipts,
            uint64_t admitted_submit_order);
    bool execute_country_worker_stage(
            int64_t day, uint64_t input_generation,
            const std::vector<RuntimeCommandPacket> &day_commands,
            RuntimeDayCommit &commit, std::string &error,
            uint64_t admitted_submit_order);
    void bind_shadow_country_peer_mirrors_locked();
    void record_country_parity_locked(const RuntimeCountryPodSnapshot &worker);
    bool flush_country_economy_asset_commits(std::string &error);
    bool country_authority_drain_idle_locked() const;
    bool publish_country_worker_snapshot(uint32_t dirty_families,
                                         std::string &error);
    bool execute_ideology_worker_stage(int64_t day,
                                       RuntimeDayCommit &commit,
                                       std::string &error);
    // G8 in-worker bridge: Ideology transition intents target EFFECT, and under
    // ACTIVE the worker owns both domains. Draining them here lets a pending
    // transition settle on the next Ideology visit instead of waiting a frame
    // for the main-thread pump. The main-thread pump stays as the protocol
    // path for sessions that grant IDEOLOGY without EFFECT.
    uint32_t ack_ideology_intents_in_worker(int64_t day);
    bool execute_trigger_worker_stage(int64_t day, uint64_t input_generation,
                                      RuntimeDayCommit &commit,
                                      std::string &error);
    // Day-local publish of Trigger effect intents. Ids are monotonic inside the
    // authority and a discarded plan replays the same ones, so the watermark is
    // what stops an ACK-barrier retry from queueing a duplicate.
    void publish_trigger_intents_locked(
            const std::vector<RuntimeTriggerEffectIntent> &intents);
    // H8 in-worker bridge, same shape as ack_ideology_intents_in_worker: Trigger
    // effect intents are delivered by the Effect stage under a joint grant, so
    // the ACK barrier settles on the next Trigger visit instead of waiting a
    // frame for the main-thread pump.
    uint32_t ack_trigger_intents_in_worker(int64_t day);
    bool execute_effect_worker_stage(int64_t day, uint64_t input_generation,
                                     RuntimeDayCommit &commit,
                                     std::string &error);
    // E8: shared Modifier POD stage for SHADOW diagnostics and ACTIVE
    // production. authority_plan is non-null only on SHADOW (fixture ACK /
    // domain-runner commit). ACTIVE passes nullptr. Failure isolates
    // Modifier — callers must not roll back Climate/Country already
    // committed the same day.
    bool execute_modifier_worker_stage(
            int64_t day, uint64_t input_generation,
            const std::vector<RuntimeCommandPacket> &day_commands,
            bool effect_upstream_ok,
            RuntimeDomainAuthorityPlan *authority_plan,
            std::string &authority_error,
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
    // Returns true when an armed one-shot injection matched `point` and
    // transitioned the worker into FAULTED. Call sites must abort the current
    // boundary immediately after a true return.
    bool try_fault_injection(const char *point) noexcept;
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
    bool serialize_country_economy_asset_journal(
            std::vector<uint8_t> &out, std::string &error) const;
    bool restore_country_economy_asset_journal(
            const uint8_t *bytes, size_t size, std::string &error);
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
    std::atomic<uint32_t> _active_evidence_mask{0};
    std::atomic<uint32_t> _completion_gate_missing_domain_mask{0};
    std::atomic<bool> _active_gate_blocked{false};
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
    // M4/M5 diagnostics. These fields describe the frozen input manifest and
    // the committed visual-intent batch without exposing worker vectors.
    std::atomic<uint64_t> _input_capture_count{0};
    std::atomic<uint64_t> _input_capture_reused{0};
    std::atomic<uint64_t> _input_capture_generation{0};
    std::atomic<int64_t> _input_capture_day{-1};
    std::atomic<uint64_t> _input_capture_hash{0};
    // Worker-owned frozen manifest. The scalar report fields above are the
    // lock-free diagnostic projection; this POD value is retained for the
    // current day barrier and ECP2/checkpoint handoff.
    RuntimeInputCaptureManifest _input_manifest{};
    std::atomic<uint64_t> _gameplay_effect_generation{0};
    std::atomic<uint32_t> _gameplay_effect_pending{0};
    std::atomic<uint32_t> _gameplay_effect_terminal{0};
    std::atomic<uint64_t> _gameplay_effect_state_hash{0};
    std::atomic<uint64_t> _visual_intent_generation{0};
    std::atomic<uint32_t> _visual_intent_count{0};
    std::atomic<bool> _visual_full_refresh{false};
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
    // B8 P3：主线程交付等待专用。不能复用 _control_cv —— worker 的日循环也在
    // 同一个 CV 上等 preflight 重试，而 worker 自己在消费环境后 notify 会让它
    // 自唤醒自旋（实测 50 天内 3200 万次不提交的重试）。
    std::condition_variable _climate_wait_cv;
    std::atomic<uint32_t> _reaper_count{0};
    std::thread _worker;
    RuntimeSnapshotRing _snapshots;
    std::shared_ptr<const RuntimeEnvironmentSnapshot> _environment_snapshot;
    RuntimeEnvironmentInputRing _environment_ring;
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
    // B8 P0 delivery cursors. `published` counts accepted publishes; `consumed`
    // counts plan attempts (not commits) so the main thread can wait for an
    // input to be *seen* without requiring the day to succeed. `superseded`
    // counts published days that a newer publish overwrote before the worker
    // planned against them — the single latest-value slot's silent loss.
    std::atomic<uint64_t> _environment_published_days{0};
    std::atomic<uint64_t> _environment_consumed_days{0};
    std::atomic<uint64_t> _environment_superseded_days{0};
    std::atomic<uint64_t> _environment_dropped_days{0};
    std::atomic<uint64_t> _climate_consumed_generation{0};
    // 上一个被记录进 environment_consumed_days 的代次。无效天重试会反复评估同一
    // 份环境；把它算成"消费了一天"会让计数变成重试次数而不是交付天数。
    std::atomic<uint64_t> _climate_last_counted_generation{0};
    std::atomic<uint64_t> _climate_wait_total_ms{0};
    std::atomic<uint64_t> _climate_wait_last_ms{0};
    std::atomic<uint64_t> _climate_wait_max_ms{0};
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
    std::map<int64_t, RuntimeCountryPodSnapshot> _country_references;
    std::deque<CountryPeerResult> _country_shadow_peer_mirrors;
    std::atomic<uint8_t> _country_parity_compared{0};
    std::atomic<uint8_t> _country_parity_matched{0};
    std::atomic<uint64_t> _country_parity_compared_count{0};
    std::atomic<uint64_t> _country_parity_matched_count{0};
    std::atomic<int64_t> _country_parity_first_mismatch_day{-1};
    std::atomic<uint64_t> _country_parity_reference_hash{0};
    std::atomic<uint64_t> _country_parity_worker_hash{0};
    std::atomic<int32_t> _country_parity_index{-1};
    std::array<std::atomic<char>, 64> _country_parity_status{};
    std::array<std::atomic<char>, 48> _country_parity_field{};
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
    // Request ids that already crossed the Host transport boundary. A worker
    // continuation must not enqueue the same request again merely because the
    // Economy coordinator polled it from the queue.
    std::unordered_set<uint64_t> _country_economy_asset_dispatched;
    RuntimeEconomyAssetProtocolStatus _country_economy_asset_protocol{};
    std::deque<uint64_t> _economy_origin_asset_queue;
    std::unordered_set<uint64_t> _country_economy_asset_committed;
    CountryAuthorityOwner _country_authority_owner =
        CountryAuthorityOwner::SYNC;
    CountryAuthorityOwner _country_authority_prepared =
        CountryAuthorityOwner::SYNC;
    bool _country_authority_prepare_pending = false;
    std::array<char, 64> _country_authority_handoff_reason{};
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
    std::atomic<bool> _economy_pod_ready{false};
    std::atomic<bool> _economy_pod_committed{false};
    std::atomic<bool> _economy_pod_authority_ready{false};
    std::atomic<int64_t> _economy_pod_committed_day{-1};
    std::atomic<int64_t> _economy_pod_epoch_sample_day{-1};
    std::atomic<uint64_t> _economy_pod_generation{0};
    std::atomic<uint64_t> _economy_pod_state_hash{0};
    std::atomic<uint64_t> _economy_pod_input_generation{0};
    std::atomic<uint64_t> _economy_pod_country_generation{0};
    std::atomic<uint32_t> _economy_pod_completed_stage_mask{0};
    std::atomic<uint32_t> _economy_pod_pending_outbox{0};
    std::atomic<uint32_t> _economy_pod_pending_inbox{0};
    std::atomic<uint32_t> _economy_pod_operation_gate_mask{0};
    std::atomic<uint32_t> _economy_pod_parity_ready_mask{0};
    std::atomic<bool> _economy_sync_writes_forbidden{false};
    std::atomic<uint32_t> _economy_replay_completed_stage_mask{0};
    std::atomic<uint32_t> _economy_replay_stage_cursor{0};
    std::atomic<uint64_t> _economy_replay_input_hash{0};
    std::atomic<uint64_t> _economy_replay_base_hash{0};
    std::atomic<uint64_t> _economy_replay_next_hash{0};
    std::array<std::atomic<uint64_t>, RUNTIME_ECONOMY_GRAPH_STAGE_COUNT>
        _economy_replay_stage_hash{};
    std::array<std::atomic<uint64_t>, RUNTIME_ECONOMY_GRAPH_STAGE_COUNT>
        _economy_replay_stage_work{};
    std::array<std::atomic<double>, RUNTIME_ECONOMY_GRAPH_STAGE_COUNT>
        _economy_replay_stage_ms{};
    std::atomic<bool> _economy_replay_input_captured{false};
    std::atomic<bool> _economy_replay_committed{false};
    std::atomic<bool> _economy_replay_parity_ready{false};
    std::array<std::atomic<char>, 64> _economy_replay_fallback_reason{};
    std::atomic<int64_t> _economy_reference_day{-1};
    std::atomic<uint64_t> _economy_reference_generation{0};
    std::atomic<uint64_t> _economy_reference_hash{0};
    std::array<std::atomic<uint64_t>, RUNTIME_ECONOMY_GRAPH_STAGE_COUNT>
        _economy_stage_reference_hash{};
    std::array<std::atomic<uint64_t>, RUNTIME_ECONOMY_GRAPH_STAGE_COUNT>
        _economy_stage_reference_work{};
    std::array<std::atomic<uint8_t>, RUNTIME_ECONOMY_GRAPH_STAGE_COUNT>
        _economy_stage_reference_present{};
    RuntimeEconomyPodAuthority _economy_pod_authority;
    std::unique_ptr<EconomyGraphStageOps> _economy_stage_ops;
    // Default ACTIVE_ONLY; StageOps mutate/writer are armed at worker start
    // (Phase-2.4.5 defaults: mutate=true, writer=stage_ops).
    std::atomic<uint32_t> _economy_execution_mode{
        static_cast<uint32_t>(EconomyExecutionMode::ACTIVE_ONLY)};
    std::atomic<bool> _economy_shadow_probe_enabled{false};
    std::atomic<bool> _economy_stage_ops_mutate{false};
    std::atomic<bool> _economy_auto_pod_active{false};
    std::atomic<bool> _economy_ecp2_dual_write{true};
    std::atomic<bool> _economy_ecp2_mid_epoch_save{false};
    std::atomic<bool> _economy_ecp2_authority{false};
    std::atomic<uint64_t> _economy_authority_switch_count{0};
    std::atomic<uint64_t> _economy_authority_switch_before_hash{0};
    std::atomic<uint64_t> _economy_authority_switch_after_hash{0};
    std::atomic<uint64_t> _economy_authority_switch_latency_us{0};
    std::atomic<uint64_t> _economy_authority_switch_latency_p95_us{0};
    std::atomic<uint64_t> _economy_authority_switch_latency_max_us{0};
    std::atomic<uint64_t> _economy_authority_switch_command_latency_us{0};
    std::atomic<uint64_t> _economy_authority_switch_command_latency_p95_us{0};
    std::atomic<uint64_t> _economy_authority_switch_command_latency_max_us{0};
    std::atomic<uint64_t> _economy_authority_switch_latency_sample_count{0};
    std::array<std::atomic<uint64_t>,
               ECONOMY_AUTHORITY_SWITCH_LATENCY_SAMPLE_CAPACITY>
        _economy_authority_switch_latency_samples{};
    std::array<std::atomic<uint64_t>,
               ECONOMY_AUTHORITY_SWITCH_LATENCY_SAMPLE_CAPACITY>
        _economy_authority_switch_command_latency_samples{};
    // The write cursor is published after both sample slots are written.
    // Authority switches are serialized by _economy_authority_boundary_mutex;
    // readers only need acquire ordering and never wait on this ring.
    std::atomic<uint64_t> _economy_authority_switch_latency_sample_write{0};
    std::atomic<uint64_t> _economy_authority_switch_rejected{0};
    std::atomic<uint64_t> _economy_authority_switch_audit_sequence{0};
    std::atomic<uint64_t> _economy_authority_switch_audit_hash{0};
    std::atomic<uint64_t> _economy_authority_switch_before_generation{0};
    std::atomic<uint64_t> _economy_authority_switch_after_generation{0};
    std::atomic<uint64_t> _economy_authority_last_committed_generation{0};
    std::atomic<uint64_t> _economy_authority_last_committed_hash{0};
    std::atomic<bool> _economy_authority_fault_paused{false};
    std::array<std::atomic<char>, 64> _economy_authority_switch_reason{};
    std::array<std::atomic<char>, 64> _economy_authority_switch_blocker{};
    std::array<std::atomic<char>, 128> _economy_authority_switch_audit_before{};
    std::array<std::atomic<char>, 128> _economy_authority_switch_audit_after{};
    // A switch is valid only while the worker is between semantic day plans.
    // These counters make that boundary observable instead of inferring it
    // from the command ring alone (the worker owns a private pending vector).
    std::atomic<uint32_t> _worker_day_inflight{0};
    std::atomic<uint32_t> _economy_inflight_mutations{0};
    std::atomic<uint32_t> _economy_pending_command_count{0};
    std::atomic<uint64_t> _last_command_admitted_us{0};
    // Serializes the semantic-day transaction with an explicit Economy
    // authority handoff.  The counters above are diagnostic evidence; this
    // mutex is the actual epoch-boundary gate that prevents a switch from
    // passing an idle check while the worker starts the next day.
    mutable std::mutex _economy_authority_boundary_mutex;
    std::atomic<uint64_t> _economy_pod_command_recapture_count{0};
    std::atomic<uint64_t> _economy_pod_command_verify_count{0};
    // Phase-2.4.4.4 soak experiment flag (observability). Parity latch defaults
    // true after Phase-2.4.5 dual-path handoff.
    std::atomic<bool> _economy_stage_ops_soak_experiment{false};
    std::atomic<bool> _economy_stage_ops_soak_parity_ok{true};
    std::atomic<uint32_t> _economy_production_writer_requested{
        static_cast<uint32_t>(EconomyProductionWriter::STAGE_OPS)};
    std::atomic<uint32_t> _economy_production_writer_effective{
        static_cast<uint32_t>(EconomyProductionWriter::STAGE_OPS)};
    // Phase-2.4.4.2: StageOps Host day-loop continuation (ACTIVE writer path).
    enum class StageOpsDayPhase : uint8_t {
        Prelude = 0,
        PlanEpoch = 1,
        AdvanceStages = 2,
        CommitEpoch = 3,
        Done = 4,
    };
    int64_t _stage_ops_day_index = -1;
    uint64_t _stage_ops_day_input_generation = 0;
    StageOpsDayPhase _stage_ops_day_phase = StageOpsDayPhase::Done;
    std::atomic<uint8_t> _stage_ops_day_phase_atomic{
        static_cast<uint8_t>(StageOpsDayPhase::Done)};
    std::atomic<uint64_t> _economy_shadow_stage_invocations{0};
    std::atomic<uint64_t> _economy_shadow_stage_cache_hits{0};
    // Parity stage-result cache keyed by (sample_day, input_generation).
    // Avoids re-running SHADOW StageOps for the same frozen input workset.
    int64_t _economy_shadow_cache_day = -1;
    uint64_t _economy_shadow_cache_input_generation = 0;
    uint64_t _economy_shadow_cache_country_generation = 0;
    uint64_t _economy_shadow_cache_catalog_hash = 0;
    bool _economy_shadow_cache_valid = false;
    std::unique_ptr<EconomyPodCommandExecutor> _economy_pod_command_executor;
    // Non-owning: DCWorldExt's NativeEconomyRuntime, ACTIVE production only.
    NativeEconomyRuntime *_economy_production_runtime = nullptr;
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
    // B8-2：worker 自持 cyclone 的当日事实。见
    // RuntimeThreadReport::climate_cyclone_alive。
    std::atomic<int32_t> _climate_cyclone_alive{0};
    std::atomic<int32_t> _climate_cyclone_injected{0};
    std::atomic<int32_t> _climate_cyclone_replaced{0};
    std::atomic<int32_t> _climate_cyclone_decayed{0};
    std::atomic<int32_t> _climate_cyclone_touched{0};
    std::atomic<double> _time_debt_days{0.0};
    std::array<std::atomic<char>, 64> _fault_code{};
    // Controllable one-shot fault injection. Empty / disarmed by default so
    // production paths never trip. Point names are stable ASCII tokens such as
    // "economy.plan.before" or "authority.switch.after".
    std::atomic<bool> _fault_injection_armed{false};
    std::atomic<uint64_t> _fault_injection_trip_count{0};
    std::array<std::atomic<char>, 64> _fault_injection_point{};
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
    RuntimeEffectSnapshotRing _effect_snapshots;
    bool _effect_pod_configured = false;
    struct EffectPodMetricQueueItem {
        int64_t instance_id = 0;
        uint32_t generation = 0;
        int32_t metric_id = 0;
        int64_t revision = 0;
        int64_t value = 0;
    };
    struct EffectPodRemoveQueueItem {
        int64_t instance_id = 0;
        uint32_t generation = 0;
    };
    mutable std::mutex _effect_transport_mutex;
    std::deque<RuntimeEffectPodInstanceInput> _effect_instance_queue;
    std::deque<EffectPodMetricQueueItem> _effect_metric_queue;
    std::deque<EffectPodRemoveQueueItem> _effect_remove_queue;
    std::deque<RuntimeDomainIntent> _effect_intents;
    std::deque<RuntimeDomainAck> _effect_acks;
    // Day-local MODIFIER-targeted intents produced by the Effect stage for
    // Modifier E7. Cleared at the start of each Effect stage visit.
    std::vector<RuntimeDomainIntent> _effect_day_modifier_intents;
    std::vector<RuntimeDomainIntent> _effect_day_intents;
    bool _effect_day_stage_ok = false;
    std::atomic<bool> _effect_pod_ready{false};
    std::atomic<double> _effect_pod_plan_ms{0.0};
    std::atomic<double> _effect_pod_replay_ms{0.0};
    std::atomic<uint64_t> _effect_pod_state_hash{0};
    std::atomic<uint64_t> _effect_pod_snapshot_generation{0};
    std::atomic<uint32_t> _effect_pod_ack_count{0};
    std::atomic<uint32_t> _effect_pod_intent_count{0};
    std::array<std::atomic<char>, 64> _effect_pod_fallback_reason{};
    mutable std::mutex _ideology_transport_mutex;
    RuntimeIdeologyPodAuthority _ideology_pod_authority;
    RuntimeIdeologyPodCatalog _ideology_pod_catalog;
    bool _ideology_pod_configured = false;
    std::shared_ptr<const RuntimeIdeologyOpinionSnapshot> _ideology_opinion_snapshot;
    std::shared_ptr<const RuntimeIdeologyPodSnapshot> _ideology_snapshot;
    // G8 ACTIVE write-back boundary. The shared_ptr above stays for SHADOW
    // consumers; the ring is the immutable main-thread apply path.
    RuntimeIdeologySnapshotRing _ideology_snapshots;
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
    // H7/H8 Trigger transport. The POD authority itself lives in
    // _domain_authority_runner (shared with the SHADOW probe); these are the
    // ACTIVE-only boundaries around it.
    mutable std::mutex _trigger_transport_mutex;
    RuntimeTriggerSnapshotRing _trigger_snapshots;
    std::deque<RuntimeTriggerEffectIntent> _trigger_intents;
    std::deque<RuntimeDomainAck> _trigger_acks;
    int64_t _trigger_published_intent_id = 0;
    std::atomic<bool> _trigger_pod_ready{false};
    std::atomic<double> _trigger_pod_plan_ms{0.0};
    std::atomic<double> _trigger_pod_replay_ms{0.0};
    std::atomic<uint64_t> _trigger_pod_state_hash{0};
    std::atomic<uint64_t> _trigger_pod_snapshot_generation{0};
    std::atomic<uint32_t> _trigger_pod_intent_count{0};
    std::atomic<uint32_t> _trigger_pod_ack_count{0};
    std::array<std::atomic<char>, 64> _trigger_pod_fallback_reason{};
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
    std::atomic<uint64_t> _climate_committed_input_generation{0};
    // 主线程 writeback 已应用的 input_generation；诊断用，不再驱动 pending 判定。
    std::atomic<uint64_t> _climate_writeback_input_generation{0};
    // 生成/恢复快照是已存在的基线，不是待执行的日输入。
    std::atomic<int64_t> _climate_bootstrap_day{0};
    mutable std::mutex _environment_publish_mutex;
    // Reused worker-local output arenas; no per-day heap growth in the hot
    // loop. They are never exposed to Godot or another thread.
    std::vector<RuntimeVisualIntent> _pod_visual_intents;
    std::vector<RuntimeCommandReceipt> _pod_receipts;
};

} // namespace pk

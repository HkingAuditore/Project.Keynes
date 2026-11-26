#pragma once

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <limits>
#include <deque>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string.hpp>

#include "runtime_pod_protocol.h"
#include "country_core.h"
#include "country_api.h"
#include "country_fiscal_return_intent.h"
#include "country_procurement_intent.h"

namespace pk {

class EffectRuntime;
class EffectInstanceForwarder;

class ModifierRuntime;
class NativeEconomyRuntime;
class CountryHostPort;

// Sole mutable authority for country identity, territory, country technology,
// and treasury state. Godot values are converted at coarse API boundaries;
// graph stages and economy reads use only POD/SoA storage.
class NativeCountryRuntime : public CountryApi {
    friend class CountryFiscalReturnPort;
public:
    CountryFiscalReturnPort fiscal_return_port();
    CountryProcurementPort procurement_port();
    // Tax kind/mode and command/asset opcode contracts live in CountryApi so
    // peer modules can name them without this internal header.
    using TaxKind = CountryApi::TaxKind;
    using TaxAssessmentMode = CountryApi::TaxAssessmentMode;

    using CommandOpcode = CountryApi::CommandOpcode;
    static constexpr uint64_t receiver_handle_from_payload(int32_t cell,
                                                           int32_t aux) {
        return (static_cast<uint64_t>(static_cast<uint32_t>(aux)) << 32U) |
               static_cast<uint64_t>(static_cast<uint32_t>(cell));
    }

    enum RuntimeMode : int32_t { MODE_OFF = 0, MODE_PROBE = 1, MODE_ACTIVE = 2 };

    using EffectCommand = CountryEffectCommand;

    using CellTaxOverride = CountryReadView::CellTaxOverride;
    using CellTaxPolicy = CountryReadView::CellTaxPolicy;

    struct ResolvedTaxPolicy {
        int32_t mode = TAX_MODE_PERCENT_BP;
        int32_t value = 0;
    };

    using EconomySnapshot = CountryEconomySnapshot;

    using EraRewardReference = CountryApi::EraRewardReference;

    godot::Dictionary configure(const godot::Dictionary &catalog,
                                const godot::Dictionary &profile,
                                int32_t cell_count, int64_t seed);
    godot::Dictionary bootstrap(const godot::Dictionary &packet,
                                const godot::PackedByteArray &is_water);
    godot::Dictionary submit_commands(const godot::Dictionary &batch);
    bool submit_typed_commands(const CountryTypedCommand *commands, size_t count,
                               std::vector<CountryCommandReceipt> &receipts,
                               std::string &error);
    bool poll_typed_receipt(CountryCommandReceipt &out);
    bool seal_boundary(uint64_t session_epoch, uint64_t boundary_id,
                       int64_t day, CountryBoundarySeal &out,
                       std::string &error);
    uint64_t session_epoch() const { return _session_epoch; }
    // Destructive contract probe for a dedicated test runtime. Exercises the
    // typed receipt lifecycle and seal watermark without a second algorithm.
    bool protocol_contract_self_test(std::string &error);
    // Destructive probe for opcodes 23/24/27 on the synchronous path plus
    // worker-kernel (country_core_apply_command) parity. Callers run it on a
    // detached copy; protocol_contract_self_test does so automatically.
    bool military_opcode_self_test(std::string &error);
    godot::Dictionary submit_observation_batch(
        int64_t handle, const godot::PackedInt32Array &cells,
        const godot::PackedInt32Array &signals, int64_t effective_day);
    bool submit_effect_commands_pod(const EffectCommand *commands, size_t count,
                                    std::vector<int64_t> &request_ids,
                                    std::string &error);
    // When Country is worker-authoritative, Effect commands are admitted to
    // the Host queue instead of the sync facade. Drain terminal receipts so
    // EffectRuntime ACK can leave PREFLIGHTED.
    void drain_effect_host_command_receipts();
    bool effect_command_result_pod(int64_t request_id, bool &complete,
                                   bool &ok, std::string &reason) const;
    bool has_pending_effect_commands() const;
    std::vector<uint8_t> capture_effect_adapter() const;
    void restore_effect_adapter(const std::vector<uint8_t> &bytes);
    bool should_run(int64_t day_index) const;
    // Pending future technology activations are not a half-applied Country
    // command. Annual snapshots must wait for the actual batch/seal only.
    bool annual_snapshot_ready() const { return !_command_batch.active && !_boundary_seal_active; }
    // Godot-free execution adapter. It shares the exact command/research core
    // used by run_slice(); peer-backed research still requires the explicit
    // cross-domain bridge before a worker may invoke it.
    bool run_day_pod(const RuntimeCountryDayContext &context,
                     RuntimeCountryDayCommit &out);
    // Capture and validate the immutable peer facts used by one Country
    // research boundary. The capture is a main-thread adapter operation; the
    // returned object is safe to hand to a worker because it contains no
    // Godot values or runtime pointers.
    bool capture_peer_context(int64_t day, uint32_t continuation_index,
                              CountryPeerContext &out,
                              std::string &error) const;
    // Exercises request identity, stale-session rejection and idempotent
    // technology-effect handling without changing the production authority
    // mode. This is intentionally separate from the worker authority gate.
    bool peer_protocol_self_test(std::string &error);
    // Worker-side peer bridge.  The Country core owns the pending intent and
    // result identity; the host owns execution of the peer runtime.
    void set_peer_async_mode(bool enabled);
    bool peer_async_mode() const { return _peer_async_mode; }
    bool poll_peer_intent(CountryPeerIntent &out);
    bool submit_peer_result(const CountryPeerResult &result,
                            std::string &error);
    struct PeerAdapterServiceReport {
        uint32_t inspected = 0;
        uint32_t completed = 0;
        uint32_t pending = 0;
        uint32_t rejected = 0;
        uint32_t effect_intents = 0;
        uint32_t modifier_intents = 0;
        uint32_t economy_intents = 0;
        uint64_t last_request_id = 0;
        std::string last_reason;
    };
    // Main-thread adapter only. It executes queued typed intents against the
    // attached peer runtimes and returns results through the same protocol
    // boundary used by a future Host outbox/inbox. Worker code must not call it.
    bool service_peer_intents_main_thread(
        int32_t max_intents, PeerAdapterServiceReport &out,
        std::string &error);
    // Host-owned Country worker adapter. This reuses the production peer
    // semantics above, but validates the worker session/generation at the
    // Host boundary instead of comparing it with the legacy synchronous
    // Country runtime session. No Country state is mutated by this call;
    // only the attached peer runtimes may enqueue/apply their own work.
    CountryPeerResult execute_peer_intent_from_worker(
        const CountryPeerIntent &intent);
    CountryPeerProtocolStatus peer_protocol_status() const;
    bool has_peer_save_barrier() const {
        return peer_protocol_status().has_save_barrier();
    }
    uint32_t pending_peer_intent_count() const {
        return static_cast<uint32_t>(_peer_pending_intents.size());
    }
    // Copy the numeric Country authority into a worker-safe immutable
    // projection. This method is a main-thread capture boundary; the
    // returned snapshot contains no Godot values or string references.
    bool export_pod_snapshot(RuntimeCountryPodSnapshot &out,
                             std::string &error) const;
    // Main-thread capture of the numeric technology/research catalog. This
    // is deliberately separate from export_pod_snapshot so a worker can
    // reject a missing or stale catalog before accepting commands.
    bool export_pod_catalog(RuntimeCountryPodCatalog &out,
                            std::string &error) const;
    godot::Dictionary run_slice(const godot::Dictionary &ctx);
    godot::Dictionary report() const;
    godot::Dictionary reset(const godot::String &reason);

    // Diagnostic-only production reference trace. Frames are captured at
    // Country semantic boundaries and contain deterministic per-state-family
    // hashes plus command/event watermarks. The full canonical PKCN payload is
    // captured explicitly so normal tracing never copies the complete store.
    godot::Dictionary configure_reference_trace(bool enabled,
                                                 int32_t max_frames = 4096);
    godot::Dictionary poll_reference_trace(int64_t after_frame_id = 0,
                                           int32_t limit = 128) const;
    godot::Dictionary capture_reference_checkpoint() const;
    bool capture_core_checkpoint(CountryCoreCheckpoint &out,
                                 std::string &error) const;
    bool restore_compatibility_state(const std::vector<uint8_t> &bytes,
                                     std::string &error);
    bool capture_worker_committed_checkpoint(CountryCoreCheckpoint &out,
                                             std::string &error) const;
    bool restore_core_checkpoint(const CountryCoreCheckpoint &checkpoint,
                                 std::string &error);

    // Main-thread presentation replica only; never installed into the authority.
    // Returns false when the committed snapshot shape is rejected so callers can
    // keep retrying instead of locking onto a stale read view.
    bool apply_committed_read_snapshot(const RuntimeCountryPodSnapshot &snapshot);

    godot::Dictionary cell_summary(int32_t cell) const;
    godot::Dictionary country_summary(int64_t handle) const;
    godot::Dictionary country_snapshot(int64_t handle) const;
    int32_t political_regime_id_for_slot(int32_t slot) const;
    uint32_t political_regime_capabilities_for_slot(int32_t slot) const;
    godot::Dictionary political_regime_snapshot(int64_t handle) const;
    godot::PackedStringArray completed_technology_ids(int64_t handle) const;
    bool has_completed_technology(int64_t handle, int32_t technology_id) const;
    int32_t visual_era_index_for_slot(int32_t slot) const;
    uint64_t visual_era_generation() const { return _visual_era_generation; }
    godot::Dictionary consume_visual_era_dirty_slots();
    godot::Dictionary treasury_snapshot(int64_t handle) const;
    godot::Dictionary research_snapshot(int64_t handle) const;
    godot::Dictionary research_signal_snapshot(int64_t handle) const;
    godot::Dictionary tax_policy_snapshot(int64_t handle) const;
    godot::Dictionary cell_tax_policy_snapshot(int32_t cell) const;
    godot::PackedInt32Array cell_country_snapshot() const;
    int64_t state_hash() const;
    int64_t state_hash_v3_compat() const;
    void mark_slot_publication(bool published, double publish_ms,
                               const godot::String &reason = {});

    godot::Dictionary begin_save(int32_t chunk_bytes);
    godot::PackedByteArray read_save_chunk(int32_t max_bytes);
    godot::Dictionary end_save();
    godot::Dictionary begin_restore();
    godot::Dictionary feed_restore_chunk(const godot::PackedByteArray &chunk);
    godot::Dictionary end_restore();

    godot::Dictionary poll_events(int64_t after_event_id, int32_t limit) const;

    // Narrow native economy bridge. These methods never allocate and never
    // resolve strings. Frozen cycles use copy_economy_snapshot(); direct
    // transfers validate generation-bearing handles.
    bool copy_economy_snapshot(EconomySnapshot &out) const;
    // Static catalog handoff for Economy's one-time configuration. Keep this
    // out of the per-epoch EconomySnapshot so the domain table is not copied
    // every day.
    bool copy_technology_domains(std::vector<int32_t> &out) const;
    // When Country is worker-authoritative, pins country_asset_snapshot() the
    // same way copy_economy_snapshot / cash_for_slot do. Sync-store bits stop
    // advancing after handoff and must not drive Economy live technology gates.
    bool has_technology(int32_t country_slot, int32_t technology_id) const;
    // Native peer runtimes may read this compact fact bitset at their own
    // scheduled boundary.  Research evidence remains Country authority.
    bool has_research_signal(int32_t country_slot, int32_t signal_id) const;
    int32_t research_signal_evidence_count(int32_t country_slot,
                                           int32_t signal_id) const;
    // Worker-authoritative reads pin cell_country_slot from the committed
    // Country asset snapshot; otherwise territory ownership drifts from UI.
    int32_t country_slot_for_cell(int32_t cell) const;
    int32_t starting_country_slot() const { return _starting_country_slot; }
    // Capital cell for a dense country slot; -1 when unset/invalid.
    int32_t capital_cell_for_slot(int32_t country_slot) const;
    int64_t country_handle_for_cell(int32_t cell) const;
    bool valid_handle(int64_t handle) const;
    int64_t total_cash() const;
    CountryReadView read_view() const;
    int64_t cash_for_slot(int32_t country_slot) const;
    int64_t cash_for_handle(int64_t country_handle) const;
    // When the Host grants Country worker authority, Economy must not mutate
    // this store. The flag is a unique-writer gate, not an ACTIVE promotion.
    void set_sync_store_writes_forbidden(bool forbidden) {
        _sync_store_writes_forbidden = forbidden;
    }
    bool sync_store_writes_forbidden() const {
        return _sync_store_writes_forbidden;
    }
    void attach_simulation_host(CountryHostPort *host) {
        _simulation_host = host;
    }
    int64_t last_committed_day() const { return _last_committed_day; }
    int64_t total_good(int32_t good_id) const;
    // Pin one Country asset snapshot and sample goods-ledger fields together so
    // Economy VERIFY does not mix a stale closing country_goods with a newer
    // research_consumed_total after late-fold / peer-preview catch-up.
    void sample_economy_goods_audit(int64_t &country_goods_total,
                                    int64_t &research_consumed_total,
                                    int64_t &country_cash_total) const;
    // Cumulative research-point goods consumed by the country runtime. The
    // economy uses the value at an epoch boundary to account for research
    // that runs while the market cycle is frozen.
    int64_t research_consumed_total() const;
    // Transient era-advancement sink (CONSUME_TREASURY_GOODS). Not saved, not
    // hashed; included in the goods sink sampled above.
    int64_t treasury_goods_consumed_total() const;
    int64_t good_for_handle(int64_t country_handle, int32_t good_id) const;
    // Worker-aware treasury good read (committed Country asset snapshot when
    // Country is worker authoritative).
    int64_t good_for_slot(int32_t country_slot, int32_t good_id) const;

    // K2-B typed Economy asset bridge.  The current production scheduler uses
    // the compatibility wrappers below, which execute prepare/commit/complete
    // in one non-blocking call.  The transaction identity and audit record are
    // already explicit so the same contract can be resumed across a future
    // peer ACK without changing Country business semantics.
    struct EconomyAssetTransaction {
        uint64_t transaction_id = 0;
        uint64_t session_epoch = 0;
        uint32_t origin_domain = 0;
        int64_t origin_epoch = -1;
        int32_t origin_stage = -1;
        uint64_t operation_sequence = 0;
        uint64_t request_id = 0;
        AssetOperation operation = ECONOMY_ASSET_RESEARCH_PURCHASE;
        AssetTransactionStatus status = ECONOMY_ASSET_CREATED;
        uint64_t country_handle = 0;
        int32_t country_slot = -1;
        int32_t good_id = -1;
        int64_t requested_quantity = 0;
        int64_t prepared_quantity = 0;
        int64_t committed_quantity = 0;
        int64_t requested_cash = 0;
        int64_t committed_cash = 0;
        // First Country boundary containing the decided treasury write. Peer
        // completion can arrive later and must not move this boundary.
        int64_t effective_country_day = -1;
        int64_t country_cash_before = 0;
        int64_t country_cash_after = 0;
        int64_t country_good_before = 0;
        int64_t country_good_after = 0;
        int64_t requested_goods_total = 0;
        int64_t committed_goods_total = 0;
        bool all_or_nothing = false;
        bool conservation_ok = true;
        uint64_t country_generation_before = 0;
        uint64_t peer_generation = 0;
        int64_t reserved_cash = 0;
        int64_t reserved_goods_total = 0;
        std::vector<int32_t> good_ids;
        std::vector<int64_t> good_quantities;
        std::vector<int64_t> country_goods_before;
        std::vector<int64_t> country_goods_after;
        std::string rejection_reason;
    };

    int64_t economy_reserve_fiscal_cash(
        int64_t country_handle, int64_t requested, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id = 0);
    int64_t economy_return_fiscal_cash(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id = 0);
    int64_t economy_collect_fiscal_cash(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id = 0);
    bool economy_purchase_research_points(
        int32_t country_slot, int64_t quantity, int64_t total_cost,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id = 0);
    int64_t economy_transfer_cash_to_cohort(
        int64_t country_handle, int64_t requested, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id = 0);
    int64_t economy_transfer_cash_from_cohort(
        int64_t country_handle, int64_t offered, int64_t origin_epoch,
        int32_t origin_stage, uint64_t request_id = 0);
    int64_t economy_transfer_good_to_market(
        int64_t country_handle, int32_t good_id, int64_t requested,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id = 0);
    int64_t economy_transfer_good_from_market(
        int64_t country_handle, int32_t good_id, int64_t offered,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id = 0);
    bool economy_spend_treasury_assets(
        int64_t country_handle, const int32_t *good_ids,
        const int64_t *quantities, size_t good_count, int64_t cash,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id = 0);
    // K2-B vertical slice. This is the first genuinely resumable Country/Economy
    // transaction. It reserves Country assets without mutating the committed
    // balance, waits for a typed peer prepare ACK, records a commit decision,
    // applies the Country side once, and completes only after peer-applied ACK.
    godot::Dictionary begin_economy_treasury_spend(
        int64_t country_handle, const godot::PackedInt32Array &good_ids,
        const godot::PackedInt64Array &quantities, int64_t cash,
        int64_t origin_epoch = -1, int32_t origin_stage = -1,
        uint64_t request_id = 0);
    godot::Dictionary begin_economy_fiscal_reserve(
        int64_t country_handle, int64_t requested, int64_t origin_epoch = -1,
        int32_t origin_stage = -1, uint64_t request_id = 0);
    godot::Dictionary begin_economy_fiscal_return(
        int64_t country_handle, int64_t offered, int64_t origin_epoch = -1,
        int32_t origin_stage = -1, uint64_t request_id = 0);
    godot::Dictionary begin_economy_fiscal_collect(
        int64_t country_handle, int64_t offered, int64_t origin_epoch = -1,
        int32_t origin_stage = -1, uint64_t request_id = 0);
    godot::Dictionary begin_economy_cash_to_cohort(
        int64_t country_handle, int64_t requested, int64_t origin_epoch = -1,
        int32_t origin_stage = -1, uint64_t request_id = 0);
    godot::Dictionary begin_economy_cash_from_cohort(
        int64_t country_handle, int64_t offered, int64_t origin_epoch = -1,
        int32_t origin_stage = -1, uint64_t request_id = 0);
    godot::Dictionary begin_economy_good_to_market(
        int64_t country_handle, int32_t good_id, int64_t requested,
        int64_t origin_epoch = -1, int32_t origin_stage = -1,
        uint64_t request_id = 0);
    godot::Dictionary begin_economy_good_from_market(
        int64_t country_handle, int32_t good_id, int64_t offered,
        int64_t origin_epoch = -1, int32_t origin_stage = -1,
        uint64_t request_id = 0, int64_t cash = 0);
    godot::Dictionary begin_economy_research_purchase(
        int64_t country_handle, int64_t quantity, int64_t total_cost,
        int64_t origin_epoch = -1, int32_t origin_stage = -1,
        uint64_t request_id = 0);
    godot::Dictionary acknowledge_economy_asset_peer_prepared(
        uint64_t transaction_id, uint64_t session_epoch,
        uint64_t country_generation, uint64_t peer_generation,
        bool accepted, const godot::String &reason = {});
    godot::Dictionary commit_economy_treasury_spend(uint64_t transaction_id);
    godot::Dictionary commit_economy_asset_transaction(uint64_t transaction_id);
    godot::Dictionary acknowledge_economy_asset_peer_applied(
        uint64_t transaction_id, uint64_t session_epoch,
        uint64_t country_generation, uint64_t peer_generation,
        bool accepted, const godot::String &reason = {});
    godot::Dictionary economy_asset_transaction_snapshot(
        uint64_t transaction_id) const;
    godot::Dictionary economy_asset_transaction_report() const;
    bool spend_treasury_assets(int64_t country_handle,
                               const int32_t *good_ids,
                               const int64_t *quantities,
                               size_t good_count,
                               int64_t cash);
    int64_t transfer_cash_to_cohort(int64_t country_handle, int64_t requested);
    int64_t transfer_cash_from_cohort(int64_t country_handle, int64_t offered);
    int64_t reserve_fiscal_cash(int64_t country_handle, int64_t requested);
    int64_t return_fiscal_cash(int64_t country_handle, int64_t offered);
    int64_t collect_fiscal_cash(int64_t country_handle, int64_t offered);
    int64_t transfer_good_to_market(int64_t country_handle, int32_t good_id,
                                    int64_t requested);
    int64_t transfer_good_from_market(int64_t country_handle, int32_t good_id,
                                      int64_t offered);
    bool research_procurement_policy(int32_t country_slot, bool &enabled,
                                     int64_t &remaining_points) const;
    bool purchase_research_points(int32_t country_slot, int64_t quantity,
                                  int64_t total_cost);
    int32_t technology_points_good_id() const { return _technology_points_good_id; }
    bool economy_available() const { return _configured && _bootstrapped && _mode != MODE_OFF; }
    uint64_t generation() const { return _generation; }
    int32_t good_count() const { return static_cast<int32_t>(_good_ids.size()); }
    int32_t technology_count() const { return static_cast<int32_t>(_technology_ids.size()); }
    int64_t world_seed() const { return _seed; }
    void set_era_reward_reference_pod(int64_t plan_id,
                                      int64_t offer_generation,
                                      int32_t milestone_technology,
                                      int32_t status);
    EraRewardReference era_reward_reference_pod() const {
        return _era_reward_reference;
    }
    // Read replicas do not receive this main-thread-owned reference through
    // worker snapshots; mirror it so a replica-captured PKCN matches PKEF.
    void mirror_era_reward_reference(const EraRewardReference &reference) {
        if (_era_reward_reference.plan_id == reference.plan_id &&
            _era_reward_reference.offer_generation == reference.offer_generation &&
            _era_reward_reference.milestone_technology ==
                reference.milestone_technology &&
            _era_reward_reference.status == reference.status)
            return;
        _era_reward_reference = reference;
        _state_hash_cache_valid = false;
    }
    void attach_modifier_runtime(ModifierRuntime *runtime) { _modifier_runtime = runtime; }
    void attach_economy_runtime(NativeEconomyRuntime *runtime) { _economy_runtime = runtime; }
    void attach_effect_runtime(EffectRuntime *runtime) {
        _effect_runtime = runtime;
        _effect_runtime_enabled = runtime != nullptr;
    }
    // Technology instances are Effect instances like any other, so installing
    // one has to make the same worker/legacy decision every other instance
    // write makes. Without this the bootstrap restore wrote straight into the
    // sync facade, which under F8 ACTIVE is writeback-only: the next worker
    // snapshot erased the row and the restored country silently lost every
    // technology effect.
    void attach_effect_forwarder(EffectInstanceForwarder *forwarder) {
        _effect_forwarder = forwarder;
    }
    void set_effect_runtime_enabled(bool enabled) { _effect_runtime_enabled = enabled; }

private:
#include "country_runtime_command_state.h"
#include "country_runtime_operations.h"
#include "country_runtime_state.h"
};

} // namespace pk

#pragma once

#include <algorithm>
#include <array>
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

namespace pk {

class EffectRuntime;

class ModifierRuntime;
class NativeEconomyRuntime;
class NativeSimulationHost;

// Sole mutable authority for country identity, territory, country technology,
// and treasury state. Godot values are converted at coarse API boundaries;
// graph stages and economy reads use only POD/SoA storage.
class NativeCountryRuntime {
public:
    static constexpr int32_t SCHEMA_VERSION = 13;
    static constexpr int64_t MONEY_SCALE = 10000;
    static constexpr int64_t GOODS_SCALE = 1000;
    static constexpr int32_t NEUTRAL_SLOT = -1;
    // Percent mode: signed basis points. Positive taxes are capped at 100%,
    // while subsidies may reach 1000%. Absolute mode: signed currency per
    // countable unit. INT32_MIN is reserved for inheritance on both lanes.
    static constexpr int32_t TAX_RATE_MIN_BP = -100000;
    static constexpr int32_t TAX_RATE_MAX_BP = 10000;
    static constexpr int32_t TAX_ABSOLUTE_MIN = -1000000000;
    static constexpr int32_t TAX_ABSOLUTE_MAX = 1000000000;
    static constexpr int32_t TAX_RATE_INHERIT =
        std::numeric_limits<int32_t>::min();
    static constexpr int32_t TAX_MODE_INHERIT =
        std::numeric_limits<int32_t>::min();

    enum TaxKind : int32_t {
        TAX_INCOME = 0,
        TAX_TRANSACTION = 1,
        TAX_CONSUMPTION = TAX_TRANSACTION, // Compatibility alias.
        TAX_BUSINESS = 2,
        TAX_IMPORT = 3,
        TAX_EXPORT = 4,
        TAX_KIND_COUNT = 5,
    };

    enum TaxAssessmentMode : int32_t {
        TAX_MODE_PERCENT_BP = 0,
        TAX_MODE_ABSOLUTE = 1,
    };

    enum CommandOpcode : int32_t {
        COMMAND_CREATE_COUNTRY = 1,
        COMMAND_RENAME_COUNTRY = 2,
        COMMAND_TRANSFER_TERRITORY = 3,
        COMMAND_GRANT_TECHNOLOGY = 4,
        COMMAND_SET_RESEARCH_WEIGHTS = 5,
        COMMAND_ENQUEUE_RESEARCH = 6,
        COMMAND_REMOVE_RESEARCH = 7,
        COMMAND_MOVE_RESEARCH = 8,
        COMMAND_SET_RESEARCH_BUDGET = 9,
        COMMAND_REVEAL_ALL_TECHNOLOGIES = 10,
        COMMAND_SET_TAX_DEFAULT = 11,
        COMMAND_SET_TAX_OVERRIDE = 12,
        COMMAND_CLEAR_TAX_OVERRIDE = 13,
        // Internal/domain command: static map/event evidence becomes
        // country-owned research knowledge at the country command boundary.
        COMMAND_DISCOVER_COUNTRY_SIGNAL = 14,
        COMMAND_SET_CELL_TAX_DEFAULT = 15,
        COMMAND_CLEAR_CELL_TAX_DEFAULT = 16,
        COMMAND_SET_CELL_TAX_OVERRIDE = 17,
        COMMAND_CLEAR_CELL_TAX_OVERRIDE = 18,
        COMMAND_CLEAR_CELL_TAX_POLICY = 19,
        // Effect-only territorial acquisition used by family expeditions.
        // Unlike TRANSFER_TERRITORY this is compare-and-set: the command is
        // rejected unless the committed/staged owner is still neutral.
        COMMAND_CLAIM_UNOWNED_TERRITORY = 20,
    };

    enum RuntimeMode : int32_t { MODE_OFF = 0, MODE_PROBE = 1, MODE_ACTIVE = 2 };

    // EffectRuntime's country adapter uses this POD ABI.  `payload` is
    // precompiled by the Effect catalog: [cell|aux], [domain|position], four
    // packed int16 research weights, and tax kind/item/rate respectively.
    struct EffectCommand {
        int32_t opcode = 0;
        int64_t effective_day = 0;
        int64_t sequence = 0;
        uint64_t target_handle = 0;
        uint32_t target_generation = 0;
        int64_t value = 0;
        std::array<int64_t, 4> payload{};
        uint64_t idempotency_key = 0;
        const char *stable_id = nullptr;
        const char *display_name = nullptr;
    };

    // Canonical sparse cell policy payload. Policy id 0 is implicit and means
    // complete inheritance; ids are transient runtime implementation details.
    struct CellTaxOverride {
        int32_t kind = -1;
        int32_t item = -1;
        int32_t rate = TAX_RATE_INHERIT;
        int32_t mode = TAX_MODE_INHERIT;

        bool operator==(const CellTaxOverride &other) const {
            return kind == other.kind && item == other.item &&
                   rate == other.rate && mode == other.mode;
        }
    };

    struct CellTaxPolicy {
        std::array<int32_t, TAX_KIND_COUNT> defaults{
            TAX_RATE_INHERIT, TAX_RATE_INHERIT, TAX_RATE_INHERIT,
            TAX_RATE_INHERIT, TAX_RATE_INHERIT};
        std::array<int32_t, TAX_KIND_COUNT> default_modes{
            TAX_MODE_INHERIT, TAX_MODE_INHERIT, TAX_MODE_INHERIT,
            TAX_MODE_INHERIT, TAX_MODE_INHERIT};
        std::vector<CellTaxOverride> overrides;

        bool empty() const {
            return std::all_of(defaults.begin(), defaults.end(),
                               [](int32_t rate) { return rate == TAX_RATE_INHERIT; }) &&
                   std::all_of(default_modes.begin(), default_modes.end(),
                               [](int32_t mode) {
                                   return mode == TAX_MODE_INHERIT;
                               }) &&
                   overrides.empty();
        }
        bool operator==(const CellTaxPolicy &other) const {
            return defaults == other.defaults &&
                   default_modes == other.default_modes &&
                   overrides == other.overrides;
        }
    };

    struct ResolvedTaxPolicy {
        int32_t mode = TAX_MODE_PERCENT_BP;
        int32_t value = 0;
    };

    struct EconomySnapshot {
        std::vector<int32_t> cell_country_slot;
        std::vector<uint64_t> country_handles;
        std::vector<uint64_t> country_technologies;
        std::vector<int32_t> income_tax_rates;
        std::vector<int32_t> consumption_tax_rates;
        std::vector<int32_t> business_tax_rates;
        std::vector<int32_t> import_tax_rates;
        std::vector<int32_t> export_tax_rates;
        std::vector<int32_t> income_tax_modes;
        std::vector<int32_t> consumption_tax_modes;
        std::vector<int32_t> business_tax_modes;
        std::vector<int32_t> import_tax_modes;
        std::vector<int32_t> export_tax_modes;
        std::vector<uint32_t> cell_tax_policy_ids;
        std::vector<CellTaxPolicy> cell_tax_policies;
        int32_t country_count = 0;
        int32_t technology_words = 0;
        int32_t profession_count = 0;
        int32_t good_count = 0;
        int32_t building_type_count = 0;
        uint64_t tax_policy_version = 0;
        uint64_t generation = 0;
        uint64_t state_hash = 0;
    };

    // Minimal cross-section authority for an era reward. The complete frozen
    // alternatives remain in PKEF; PKCN stores only this reference/state so a
    // restore can reject orphaned or contradictory offers.
    struct EraRewardReference {
        int64_t plan_id = 0;
        int64_t offer_generation = 0;
        int32_t milestone_technology = -1;
        int32_t status = 0;
    };

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
    bool should_run(int64_t day_index) const;
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
    bool restore_core_checkpoint(const CountryCoreCheckpoint &checkpoint,
                                 std::string &error);

    // Main-thread presentation replica only; never installed into the authority.
    // Returns false when the committed snapshot shape is rejected so callers can
    // keep retrying instead of locking onto a stale read view.
    bool apply_committed_read_snapshot(const RuntimeCountryPodSnapshot &snapshot);

    godot::Dictionary cell_summary(int32_t cell) const;
    godot::Dictionary country_summary(int64_t handle) const;
    godot::Dictionary country_snapshot(int64_t handle) const;
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
    bool has_technology(int32_t country_slot, int32_t technology_id) const;
    // Native peer runtimes may read this compact fact bitset at their own
    // scheduled boundary.  Research evidence remains Country authority.
    bool has_research_signal(int32_t country_slot, int32_t signal_id) const;
    int32_t research_signal_evidence_count(int32_t country_slot,
                                           int32_t signal_id) const;
    int32_t country_slot_for_cell(int32_t cell) const;
    int32_t starting_country_slot() const { return _starting_country_slot; }
    int64_t country_handle_for_cell(int32_t cell) const;
    bool valid_handle(int64_t handle) const;
    int64_t total_cash() const;
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
    void attach_simulation_host(NativeSimulationHost *host) {
        _simulation_host = host;
    }
    int64_t last_committed_day() const { return _last_committed_day; }
    int64_t total_good(int32_t good_id) const;
    // Cumulative research-point goods consumed by the country runtime. The
    // economy uses the value at an epoch boundary to account for research
    // that runs while the market cycle is frozen.
    int64_t research_consumed_total() const;
    int64_t good_for_handle(int64_t country_handle, int32_t good_id) const;

    // K2-B typed Economy asset bridge.  The current production scheduler uses
    // the compatibility wrappers below, which execute prepare/commit/complete
    // in one non-blocking call.  The transaction identity and audit record are
    // already explicit so the same contract can be resumed across a future
    // peer ACK without changing Country business semantics.
    enum EconomyAssetOperation : int32_t {
        ECONOMY_ASSET_RESEARCH_PURCHASE = 1,
        ECONOMY_ASSET_FISCAL_RESERVE = 2,
        ECONOMY_ASSET_FISCAL_RETURN = 3,
        ECONOMY_ASSET_FISCAL_COLLECT = 4,
        ECONOMY_ASSET_CASH_TO_COHORT = 5,
        ECONOMY_ASSET_CASH_FROM_COHORT = 6,
        ECONOMY_ASSET_GOOD_TO_MARKET = 7,
        ECONOMY_ASSET_GOOD_FROM_MARKET = 8,
        ECONOMY_ASSET_TREASURY_SPEND = 9,
    };
    enum EconomyAssetTransactionStatus : int32_t {
        ECONOMY_ASSET_CREATED = 1,
        ECONOMY_ASSET_COUNTRY_PREPARED = 2,
        ECONOMY_ASSET_PEER_PREPARED = 3,
        ECONOMY_ASSET_COMMIT_DECIDED = 4,
        ECONOMY_ASSET_COUNTRY_APPLIED = 5,
        ECONOMY_ASSET_PEER_APPLIED = 6,
        ECONOMY_ASSET_COMPLETED = 7,
        ECONOMY_ASSET_REJECTED = 8,
        // Explicit asynchronous bridge states.  The legacy values above are
        // retained for compatibility with the synchronous accounting report.
        ECONOMY_ASSET_AWAITING_PEER_PREPARED = 9,
        ECONOMY_ASSET_AWAITING_PEER_APPLIED = 10,
        ECONOMY_ASSET_FAULTED = 11,
    };
    struct EconomyAssetTransaction {
        uint64_t transaction_id = 0;
        uint64_t session_epoch = 0;
        uint32_t origin_domain = 0;
        int64_t origin_epoch = -1;
        int32_t origin_stage = -1;
        uint64_t operation_sequence = 0;
        uint64_t request_id = 0;
        EconomyAssetOperation operation = ECONOMY_ASSET_RESEARCH_PURCHASE;
        EconomyAssetTransactionStatus status = ECONOMY_ASSET_CREATED;
        uint64_t country_handle = 0;
        int32_t country_slot = -1;
        int32_t good_id = -1;
        int64_t requested_quantity = 0;
        int64_t prepared_quantity = 0;
        int64_t committed_quantity = 0;
        int64_t requested_cash = 0;
        int64_t committed_cash = 0;
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
        uint64_t request_id = 0);
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
                                     int64_t &cash_budget, int64_t &remaining_points) const;
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
    void attach_modifier_runtime(ModifierRuntime *runtime) { _modifier_runtime = runtime; }
    void attach_economy_runtime(NativeEconomyRuntime *runtime) { _economy_runtime = runtime; }
    void attach_effect_runtime(EffectRuntime *runtime) {
        _effect_runtime = runtime;
        _effect_runtime_enabled = runtime != nullptr;
    }
    void set_effect_runtime_enabled(bool enabled) { _effect_runtime_enabled = enabled; }

private:
    struct CountryStore {
        std::vector<uint8_t> active;
        std::vector<uint32_t> generation;
        std::vector<std::string> stable_id;
        std::vector<std::string> display_name;
        std::vector<int32_t> territory_count;
        std::vector<int64_t> cash;
        std::vector<uint64_t> state_version;
    };

    struct Command {
        uint64_t request_id = 0;
        uint32_t producer_id = 0;
        uint64_t observed_generation = 0;
        int32_t opcode = 0;
        int64_t effective_day = 0;
        int64_t sequence = 0;
        uint64_t target_handle = 0;
        int32_t cell = -1;
        int32_t aux = -1;
        int32_t domain = -1;
        int32_t position = -1;
        int32_t weights_bp[4] = {0, 0, 0, 0};
        int32_t tax_kind = -1;
        int32_t tax_item = -1;
        int32_t tax_rate_basis_points = 0;
        int32_t tax_assessment_mode = TAX_MODE_PERCENT_BP;
        int64_t value = 0;
        std::string stable_id;
        std::string display_name;
        uint64_t submit_order = 0;
        int64_t effect_request_id = 0;
        uint64_t effect_idempotency_key = 0;
    };

    struct Event {
        int64_t event_id = 0;
        int64_t day = 0;
        int32_t opcode = 0;
        uint64_t country_handle = 0;
        int32_t cell = -1;
        int32_t old_country_slot = -1;
        int32_t new_country_slot = -1;
        int32_t technology_id = -1;
        int32_t signal_id = -1;
        int32_t signal_source_kind = 0;
        int32_t evidence_delta = 0;
        std::string stable_id;
        std::string display_name;
    };

    struct SparseCellDelta {
        std::vector<int32_t> keys;
        std::vector<int32_t> values;
        size_t mask = 0;
        size_t count = 0;

        void reserve(size_t expected) {
            size_t capacity = 8;
            while (capacity < expected * 2 + 1) capacity <<= 1U;
            keys.assign(capacity, -1);
            values.assign(capacity, NEUTRAL_SLOT);
            mask = capacity - 1;
            count = 0;
        }
        bool get(int32_t cell, int32_t &value) const {
            if (keys.empty()) return false;
            size_t cursor = (static_cast<uint32_t>(cell) * 2654435761U) & mask;
            while (true) {
                if (keys[cursor] == -1) return false;
                if (keys[cursor] == cell) {
                    value = values[cursor];
                    return true;
                }
                cursor = (cursor + 1) & mask;
            }
        }
        bool set(int32_t cell, int32_t value) {
            size_t cursor = (static_cast<uint32_t>(cell) * 2654435761U) & mask;
            while (keys[cursor] != -1 && keys[cursor] != cell)
                cursor = (cursor + 1) & mask;
            const bool inserted = keys[cursor] == -1;
            if (inserted) { keys[cursor] = cell; ++count; }
            values[cursor] = value;
            return inserted;
        }
        size_t size() const { return count; }
        bool empty() const { return count == 0; }
    };

    struct EffectCommandResult {
        uint8_t complete = 0;
        uint8_t ok = 0;
        std::string reason;
    };

    struct SignalEvidence {
        int32_t signal = -1;
        int32_t count = 0;
        int64_t first_day = -1;
        int64_t last_day = -1;
        int32_t first_cell = -1;
    };

    struct CommandBatchState {
        bool active = false;
        int64_t day = -1;
        size_t cursor = 0;
        double preflight_ms = 0.0;
        int64_t observation_batch_input = 0;
        int64_t observation_batch_added = 0;
        CountryStore countries;
        std::vector<uint64_t> technologies;
        std::vector<int64_t> goods;
        std::vector<uint64_t> discovered;
        std::vector<uint64_t> pending;
        std::vector<std::vector<std::pair<int32_t, int64_t>>> progress;
        std::vector<int32_t> research_queues;
        std::vector<uint8_t> research_queue_lengths;
        std::vector<int32_t> research_weights_bp;
        std::vector<uint8_t> research_auto_purchase;
        std::vector<int64_t> research_daily_budgets;
        std::vector<int64_t> research_deferred_points;
        std::vector<uint64_t> signals;
        std::vector<std::vector<uint64_t>> signal_cells;
        std::vector<std::vector<SignalEvidence>> signal_evidence;
        bool stage_technologies = false;
        bool stage_goods = false;
        bool stage_research = false;
        bool stage_signals = false;
        bool stage_tax = false;
        bool stage_cell_tax = false;
        std::vector<int32_t> tax_defaults;
        std::vector<int32_t> tax_default_modes;
        std::vector<int32_t> income_tax_overrides;
        std::vector<int32_t> consumption_tax_overrides;
        std::vector<int32_t> business_tax_overrides;
        std::vector<int32_t> import_tax_overrides;
        std::vector<int32_t> export_tax_overrides;
        std::vector<int32_t> income_tax_mode_overrides;
        std::vector<int32_t> consumption_tax_mode_overrides;
        std::vector<int32_t> business_tax_mode_overrides;
        std::vector<int32_t> import_tax_mode_overrides;
        std::vector<int32_t> export_tax_mode_overrides;
        std::unordered_map<int32_t, CellTaxPolicy> cell_tax_updates;
        SparseCellDelta cell_delta;
        std::vector<int32_t> cell_delta_order;
        std::vector<int32_t> direct_cell_owners;
        bool direct_unique_territory = false;
        std::vector<Event> events;
        std::vector<Command> commands;
        std::vector<uint8_t> changed_countries;
    };

    bool validate_handle(uint64_t handle, int32_t &slot) const;
    bool validate_admission_command(const Command &command,
                                    std::string &error) const;
    void push_typed_receipt(const Command &command,
                            CountryCommandReceiptCode code,
                            const std::string &reason = {});
    CountryBoundarySeal open_implicit_boundary(int64_t day);
    void close_boundary_seal();
    CountryCoreStepResult run_slice_core(int64_t requested_day);
    uint64_t make_handle(int32_t slot) const;
    int64_t debit_country_cash(int64_t country_handle, int64_t requested,
                                const char *trace_stage);
    int64_t credit_country_cash(int64_t country_handle, int64_t offered,
                                const char *trace_stage);
    uint64_t begin_economy_asset_transaction(
        EconomyAssetTransaction &transaction, uint64_t request_id,
        uint32_t origin_domain, int64_t origin_epoch, int32_t origin_stage);
    void finish_economy_asset_transaction(EconomyAssetTransaction &transaction,
                                           bool completed,
                                           const char *rejection_reason = nullptr,
                                           bool conservation_failure = false);
    bool find_economy_asset_transaction(uint64_t request_id,
                                        EconomyAssetTransaction &out) const;
    int64_t complete_economy_asset_compatibility(
        const godot::Dictionary &begin);
    godot::Dictionary begin_economy_fiscal_cash_credit(
        EconomyAssetOperation operation, int64_t country_handle, int64_t offered,
        int64_t origin_epoch, int32_t origin_stage, uint64_t request_id,
        const char *invalid_reason);
    int32_t append_country(const std::string &stable_id,
                           const std::string &display_name, int64_t cash);
    int32_t tax_item_count(int32_t kind) const;
    const std::vector<int32_t> *tax_override_vector(int32_t kind) const;
    std::vector<int32_t> *tax_override_vector(int32_t kind);
    const std::vector<int32_t> *tax_mode_override_vector(int32_t kind) const;
    std::vector<int32_t> *tax_mode_override_vector(int32_t kind);
    static bool tax_assessment_mode_valid(int32_t mode);
    static bool tax_value_valid(int32_t mode, int32_t value);
    static int32_t resolved_tax_rate(const std::vector<int32_t> &defaults,
                                    const std::vector<int32_t> &overrides,
                                    int32_t country_slot, int32_t kind,
                                    int32_t item, int32_t item_count);
    static int32_t resolved_tax_mode(const std::vector<int32_t> &default_modes,
                                    const std::vector<int32_t> &mode_overrides,
                                    int32_t country_slot, int32_t kind,
                                    int32_t item, int32_t item_count);
    static ResolvedTaxPolicy resolved_tax_policy(
        const std::vector<int32_t> &defaults,
        const std::vector<int32_t> &default_modes,
        const std::vector<int32_t> &overrides,
        const std::vector<int32_t> &mode_overrides, int32_t country_slot,
        int32_t kind, int32_t item, int32_t item_count);
    static uint64_t cell_tax_policy_hash(const CellTaxPolicy &policy);
    uint32_t intern_cell_tax_policy(const CellTaxPolicy &policy);
    void release_cell_tax_policy(uint32_t policy_id);
    void rebuild_cell_tax_policy_intern();
    const CellTaxPolicy &cell_tax_policy(uint32_t policy_id) const;
    const std::vector<std::string> &tax_item_ids(int32_t kind) const;
    int32_t tax_item_index(int32_t kind, const std::string &stable_id) const;
    void rebuild_cell_csr();
    void publish_report(const char *stage, int64_t day, double preflight_ms,
                        double apply_ms, double publish_ms, int32_t changed_cells,
                        int32_t changed_countries, bool published, const std::string &reason = {});
    void push_event(Event event);
    uint64_t catalog_hash() const;
    uint64_t catalog_hash_v3() const;
    uint64_t compute_state_hash() const;
    struct ReferenceHashes {
        uint64_t identity = 0;
        uint64_t territory = 0;
        uint64_t treasury = 0;
        uint64_t technology = 0;
        uint64_t research = 0;
        uint64_t signals = 0;
        uint64_t tax = 0;
        uint64_t effect = 0;
    };
    struct ReferenceFrame {
        uint64_t frame_id = 0;
        uint64_t boundary_id = 0;
        uint32_t continuation_index = 0;
        int64_t day = -1;
        std::string stage;
        bool semantic_commit = false;
        bool day_barrier = false;
        uint64_t catalog_hash = 0;
        uint64_t technology_catalog_hash = 0;
        uint64_t command_watermark = 0;
        uint64_t command_hash = 0;
        uint64_t command_count = 0;
        uint64_t business_state_hash = 0;
        ReferenceHashes hashes;
        uint64_t generation = 0;
        uint64_t territory_generation = 0;
        uint64_t research_generation = 0;
        uint64_t tax_generation = 0;
        uint64_t visual_generation = 0;
        int64_t first_event_id = 0;
        int64_t last_event_id = 0;
        uint64_t effect_intent_count = 0;
        uint64_t effect_ack_count = 0;
    };
    ReferenceHashes compute_reference_hashes() const;
    uint64_t reference_command_hash(const std::vector<Command> &commands) const;
    void begin_reference_boundary(int64_t day);
    void record_reference_frame(const char *stage, int64_t day,
                                bool semantic_commit, bool day_barrier,
                                uint64_t command_hash = 0,
                                uint64_t command_count = 0,
                                int64_t first_event_id = 0);
    void record_direct_reference_frame(const char *stage);
    bool encode_save(std::vector<uint8_t> &out, std::string &error) const;
    bool decode_save(const std::vector<uint8_t> &bytes, std::string &error);
    bool decode_save_in_place(const std::vector<uint8_t> &bytes,
                              std::string &error);
    bool restore_core_checkpoint_in_place(
        const CountryCoreCheckpoint &checkpoint, std::string &error);
    void initialize_country_research(int32_t slot);
    void rebuild_pending_activation_index() const;
    // FULL/PROBE diagnostics validate the transient activation index against
    // the authoritative pending bitset.  A mismatch must fall back to the
    // deterministic technology scan for the current day.
    bool validate_pending_activation_index() const;
    void insert_pending_activation(int32_t slot, int32_t technology);
    void erase_pending_activation(int32_t slot, int32_t technology);
    bool country_has_research_work(int32_t slot) const;
    void rebuild_research_active_index();
    void rebuild_discovery_dependents();
    void refresh_discovery_for_completed(
        int32_t slot, const std::vector<int32_t> &completed);
    void refresh_discovery(int32_t slot);
    bool prerequisites_met(int32_t slot, int32_t technology) const;
    bool prerequisites_met(const std::vector<uint64_t> &completed, int32_t slot,
                           int32_t technology) const;
    bool era_entry_met(const std::vector<uint64_t> &completed, int32_t slot,
                       int32_t technology) const;
    bool research_condition_met(int32_t slot, int32_t technology) const;
    bool research_condition_met(const std::vector<uint64_t> &completed,
                                const std::vector<uint64_t> &signals,
                                const std::vector<std::vector<SignalEvidence>> &evidence,
                                int32_t slot, int32_t technology) const;
    bool reveal_condition_met(int32_t slot, int32_t technology) const;
    void refresh_discovery_for_technology(int32_t slot, int32_t technology);
    void refresh_discovery_for_signal(int32_t slot, int32_t signal);
    bool signal_present(const std::vector<uint64_t> &signals, int32_t slot,
                        int32_t signal) const;
    int32_t signal_count(int32_t slot, int32_t signal) const;
    int32_t signal_count(const std::vector<std::vector<SignalEvidence>> &evidence,
                         int32_t slot, int32_t signal) const;
    static SignalEvidence *find_signal_evidence(std::vector<SignalEvidence> &entries,
                                                int32_t signal);
    static const SignalEvidence *find_signal_evidence(
        const std::vector<SignalEvidence> &entries, int32_t signal);
    int64_t effective_research_cost(
        int32_t slot, int32_t technology,
        const CountryPeerContext *peer_context = nullptr) const;
    void ensure_research_modifier_cache(
        int32_t slot,
        const CountryPeerContext *peer_context = nullptr) const;
    // Sparse progress may exceed catalog base cost when country.research.cost_factor
    // is above 1.0. Restore validation must accept any value that effective cost
    // could legally reach under the ModifierCatalog clamp ceiling.
    int64_t max_storable_research_progress(int32_t technology) const;
    bool finalize_research_head_if_complete(int32_t slot, int32_t domain,
                                            int64_t day_index,
                                            bool use_pending_queue,
                                            CountryPeerContext *peer_context = nullptr);
    int64_t progress_for(int32_t slot, int32_t technology) const;
    void set_progress(int32_t slot, int32_t technology, int64_t value);
    int32_t run_research_day(
        int64_t day_index, const CountryPeerContext *peer_context = nullptr,
        CountryPeerContext *out_peer_context = nullptr);
    bool ensure_technology_effect_instance(
        int32_t slot, int32_t technology, int64_t day_index,
        CountryPeerContext &peer_context);
    bool ack_chain_due(
        int64_t day_index,
        const CountryPeerContext *peer_context = nullptr) const;
    CountryPeerTechnologyState *find_peer_technology_state(
        CountryPeerContext &context, int32_t slot, int32_t technology);
    const CountryPeerTechnologyState *find_peer_technology_state(
        const CountryPeerContext &context, int32_t slot,
        int32_t technology) const;
    CountryPeerTechnologyState &ensure_peer_technology_state(
        CountryPeerContext &context, int32_t slot, int32_t technology);
    CountryPeerResult apply_peer_intent(CountryPeerContext &context,
                                         const CountryPeerIntent &intent);
    CountryPeerResult execute_peer_intent_main_thread(
        const CountryPeerIntent &intent,
        bool validate_local_identity = true);
    void apply_peer_result_to_context(CountryPeerContext &context,
                                      const CountryPeerResult &result);
    bool peer_result_identity_matches(const CountryPeerIntent &intent,
                                      const CountryPeerResult &result,
                                      std::string &error) const;
    void remember_peer_rejection(const CountryPeerResult &result);
    void clear_peer_rejections_for_retry(const CountryPeerIntent &intent);
    bool peer_rejection_blocks_activation(int32_t slot, int32_t technology,
                                          int64_t day) const;
    bool peer_rejection_needs_service(int64_t day) const;
    void mark_peer_rejections_reported(int64_t day);
    bool retry_peer_rejections(int64_t day, CountryPeerContext &context);
    void clear_peer_protocol_state();
    CountryPeerIntent make_peer_intent(
        const CountryPeerContext &context, CountryPeerIntentCode opcode,
        int32_t slot, int32_t technology, int64_t day_index) const;

    bool _configured = false;
    bool _sync_store_writes_forbidden = false;
    NativeSimulationHost *_simulation_host = nullptr;
    bool _bootstrapped = false;
    RuntimeMode _mode = MODE_ACTIVE;
    int32_t _cell_count = 0;
    int64_t _seed = 0;
    int32_t _technology_words = 0;
    int32_t _research_signal_words = 0;
    int32_t _technology_points_good_id = -1;
    uint64_t _technology_catalog_identity_hash = 0;
    uint64_t _technology_content_binding_hash = 0;
    uint64_t _technology_trigger_definition_hash = 0;
    ModifierRuntime *_modifier_runtime = nullptr;
    NativeEconomyRuntime *_economy_runtime = nullptr;
    EffectRuntime *_effect_runtime = nullptr;
    bool _effect_runtime_enabled = false;
    int32_t _starting_country_slot = -1;
    uint64_t _generation = 0;
    // Visibility generations are diagnostic/publish watermarks, not separate
    // simulation authorities.  They deliberately stay out of save/state hashes.
    uint64_t _territory_generation = 0;
    uint64_t _research_generation = 0;
    bool _full_diagnostics = false;
    bool _light_report_enabled = true;
    bool _pending_queue_enabled = true;
    mutable bool _state_hash_cache_valid = false;
    mutable uint64_t _state_hash_cache = 0;
    mutable uint64_t _state_hash_cache_generation = 0;
    mutable int64_t _state_hash_cache_research_day = -1;
    mutable uint64_t _state_hash_cache_tax_policy_version = 0;
    mutable EraRewardReference _state_hash_cache_era_reward{};
    uint64_t _submit_order = 0;
    uint64_t _session_epoch = 1;
    uint64_t _next_boundary_id = 1;
    CountryBoundarySeal _boundary_seal;
    bool _boundary_seal_active = false;
    uint64_t _next_event_id = 1;
    int64_t _last_committed_day = -1;
    int32_t _max_commands_per_slice = 65536;

    std::vector<std::string> _good_ids;
    std::vector<std::string> _profession_ids;
    std::vector<std::string> _building_type_ids;
    std::vector<std::string> _technology_ids;
    std::vector<std::string> _technology_era_reward_pool_ids;
    std::vector<std::string> _research_signal_ids;
    std::unordered_map<std::string, int32_t> _good_index;
    std::unordered_map<std::string, int32_t> _technology_index;
    std::vector<int32_t> _starting_technologies;
    std::vector<int32_t> _technology_domains;
    std::vector<int64_t> _technology_costs;
    std::vector<int32_t> _technology_prerequisite_offsets;
    std::vector<int32_t> _technology_prerequisites;
    std::vector<int32_t> _technology_milestone_offsets;
    std::vector<int32_t> _technology_milestone_candidates;
    std::vector<int32_t> _technology_milestone_required_counts;
    // Dense per-technology era gate. -1 denotes the first era. This is kept
    // separate from the authored prerequisite CSR so the graph contains only
    // real knowledge dependencies.
    std::vector<int32_t> _technology_entry_milestone_indices;
    std::vector<int32_t> _technology_era_milestone_indices;
    std::vector<int32_t> _technology_flags;
    std::vector<std::string> _technology_modifier_definition_keys;
    std::vector<uint8_t> _research_signal_requires_provenance;
    std::vector<int32_t> _technology_research_condition_offsets;
    std::vector<int32_t> _technology_research_condition_ops;
    std::vector<int32_t> _technology_research_condition_refs;
    std::vector<int64_t> _technology_research_condition_values;
    std::vector<int32_t> _technology_reveal_condition_offsets;
    std::vector<int32_t> _technology_reveal_condition_ops;
    std::vector<int32_t> _technology_reveal_condition_refs;
    std::vector<int64_t> _technology_reveal_condition_values;
    std::vector<int32_t> _technology_reveal_signal_offsets;
    std::vector<int32_t> _technology_reveal_signal_technologies;
    std::vector<int32_t> _technology_discovery_dependent_offsets;
    std::vector<int32_t> _technology_discovery_dependents;
    std::vector<uint8_t> _is_water;

    CountryStore _countries;
    std::vector<int32_t> _cell_country_slot;
    std::vector<int32_t> _country_cell_offsets;
    std::vector<int32_t> _country_cells;
    std::vector<uint64_t> _country_technologies;
    std::vector<int64_t> _country_goods;
    std::vector<uint64_t> _country_discovered;
    std::vector<uint64_t> _country_pending_technologies;
    std::vector<int32_t> _current_visual_era;
    std::vector<int32_t> _visual_era_dirty_slots;
    uint64_t _visual_era_generation = 0;
    mutable std::vector<std::vector<int32_t>> _pending_activation_indices;
    mutable bool _pending_activation_index_dirty = true;
    mutable int64_t _pending_activation_count = 0;
    mutable int64_t _research_queue_rebuilds = 0;
    int64_t _research_full_scan_fallbacks = 0;
    std::string _research_queue_fallback_reason;
    std::vector<int32_t> _research_active_country_slots;
    std::vector<int32_t> _research_active_country_scratch;
    std::vector<uint8_t> _research_active_country_membership;
    // A country has four research lanes with an eight-entry queue each. Keep
    // activation scratch at the runtime level so the daily hot loop reuses
    // capacity instead of allocating two vectors for every active country.
    std::vector<int32_t> _research_activated_pending_scratch;
    std::vector<int32_t> _research_activated_technologies_scratch;
    struct ResearchModifierCache {
        uint64_t country_handle = 0;
        uint64_t modifier_version = std::numeric_limits<uint64_t>::max();
        double cost_factor = 1.0;
        std::array<double, 4> efficiency{{1.0, 1.0, 1.0, 1.0}};
    };
    mutable std::vector<ResearchModifierCache> _research_modifier_cache;
    // Per-run diagnostics. They are reset at run_research_day() entry and are
    // excluded from persistence and authoritative hashes.
    mutable double _research_activation_ms = 0.0;
    mutable double _research_allocation_ms = 0.0;
    mutable double _research_effect_ack_ms = 0.0;
    mutable double _research_discovery_ms = 0.0;
    mutable double _research_modifier_ms = 0.0;
    mutable int64_t _research_countries_scanned = 0;
    mutable int64_t _research_active_countries = 0;
    mutable int64_t _research_pending_checks = 0;
    mutable int64_t _research_discovery_checks = 0;
    mutable int64_t _research_discovery_frontier_mismatches = 0;
    mutable int64_t _research_modifier_queries = 0;
    mutable int64_t _research_modifier_cache_hits = 0;
    mutable int64_t _research_remainder_iterations = 0;
    std::string _peer_protocol_fault_reason;
    std::vector<uint64_t> _country_research_signals;
    std::vector<std::vector<uint64_t>> _country_research_signal_cells;
    std::vector<std::vector<SignalEvidence>> _country_research_signal_evidence;
    std::vector<std::vector<std::pair<int32_t, int64_t>>> _country_research_progress;
    std::vector<int32_t> _country_research_queues;
    std::vector<uint8_t> _country_research_queue_lengths;
    std::vector<int32_t> _country_research_weights_bp;
    std::vector<uint8_t> _country_research_auto_purchase;
    std::vector<int64_t> _country_research_daily_budgets;
    std::vector<int64_t> _country_research_deferred_points;
    std::vector<int64_t> _country_research_purchased_total;
    std::vector<int64_t> _country_research_consumed_total;
    std::vector<int64_t> _country_research_progress_total;
    std::vector<int64_t> _country_research_completed_total;
    // K2-A protocol diagnostics. These are not authority state and do not
    // participate in business/checkpoint hashes.
    uint64_t _peer_intents_emitted = 0;
    uint64_t _peer_results_consumed = 0;
    bool _peer_async_mode = false;
    std::unordered_map<uint64_t, CountryPeerIntent> _peer_pending_intents;
    std::deque<uint64_t> _peer_intent_queue;
    std::unordered_map<uint64_t, CountryPeerResult> _peer_result_cache;
    std::unordered_map<uint64_t, CountryPeerResult> _peer_rejected_results;
    std::unordered_set<uint64_t> _peer_rejection_reported;
    std::vector<int32_t> _country_tax_defaults;
    std::vector<int32_t> _country_tax_default_modes;
    std::vector<int32_t> _country_income_tax_overrides;
    std::vector<int32_t> _country_consumption_tax_overrides;
    std::vector<int32_t> _country_business_tax_overrides;
    std::vector<int32_t> _country_import_tax_overrides;
    std::vector<int32_t> _country_export_tax_overrides;
    std::vector<int32_t> _country_income_tax_mode_overrides;
    std::vector<int32_t> _country_consumption_tax_mode_overrides;
    std::vector<int32_t> _country_business_tax_mode_overrides;
    std::vector<int32_t> _country_import_tax_mode_overrides;
    std::vector<int32_t> _country_export_tax_mode_overrides;
    std::vector<uint32_t> _cell_tax_policy_ids;
    std::vector<CellTaxPolicy> _cell_tax_policies;
    std::vector<uint32_t> _cell_tax_policy_refcounts;
    std::vector<uint32_t> _cell_tax_policy_free_ids;
    std::unordered_map<uint64_t, std::vector<uint32_t>> _cell_tax_policy_intern;
    uint64_t _tax_policy_version = 0;
    int64_t _last_research_day = -1;
    std::vector<Command> _pending_commands;
    std::deque<CountryCommandReceipt> _typed_receipts;
    std::unordered_map<uint64_t, CountryCommandReceipt> _typed_request_state;
    std::unordered_map<int64_t, EffectCommandResult> _effect_command_results;
    std::unordered_map<uint64_t, int64_t> _effect_command_idempotency;
    // Host request_id → Effect request_id while Country writes are worker-owned.
    std::unordered_map<uint64_t, int64_t> _effect_host_request_map;
    uint64_t _effect_host_receipt_cursor = 0;
    int64_t _next_effect_request_id = 1;
    EraRewardReference _era_reward_reference;
    std::deque<Event> _events;
    CommandBatchState _command_batch;
    godot::Dictionary _report;
    bool _reference_trace_enabled = false;
    size_t _reference_trace_capacity = 4096;
    uint64_t _next_reference_frame_id = 1;
    uint64_t _reference_boundary_id = 0;
    uint32_t _reference_continuation_index = 0;
    int64_t _reference_boundary_day = -1;
    int64_t _reference_boundary_first_event_id = 0;
    std::deque<ReferenceFrame> _reference_frames;
    // Suppresses the one legacy diagnostic write in run_research_day() while
    // the POD adapter is executing on a worker-owned runtime.
    bool _pod_execution = false;

    // Diagnostic transaction ledger for the K2-B compatibility bridge.  It is
    // deliberately excluded from the Country business hash and checkpoint;
    // authoritative Country balances remain the only mutable business state.
    uint64_t _next_economy_asset_transaction_id = 1;
    uint64_t _economy_asset_operation_sequence = 0;
    uint64_t _economy_asset_transactions_created = 0;
    uint64_t _economy_asset_transactions_completed = 0;
    uint64_t _economy_asset_transactions_rejected = 0;
    uint64_t _economy_asset_prepare_count = 0;
    uint64_t _economy_asset_commit_count = 0;
    uint64_t _economy_asset_complete_count = 0;
    int64_t _economy_asset_ledger_failures = 0;
    std::deque<EconomyAssetTransaction> _economy_asset_transaction_history;
    std::unordered_map<uint64_t, uint64_t> _economy_asset_request_index;
    std::unordered_map<uint64_t, EconomyAssetTransaction>
        _economy_asset_transactions_in_flight;
    std::vector<int64_t> _economy_asset_reserved_cash;
    std::vector<int64_t> _economy_asset_reserved_goods;
    // Research procurement credits technology_points, so reserve remaining
    // int64 capacity separately from debit-side goods reservations.
    std::vector<int64_t> _economy_asset_reserved_research_points;

    std::vector<uint8_t> _save_bytes;
    size_t _save_cursor = 0;
    int32_t _save_chunk_bytes = 4 * 1024 * 1024;
    bool _save_active = false;
    std::vector<uint8_t> _restore_bytes;
    bool _restore_active = false;
};

} // namespace pk

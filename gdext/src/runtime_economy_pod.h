#pragma once

#include "economy_graph_kernels.h"
#include "runtime_economy_state.h"
#include "runtime_domain_pod.h"
#include "runtime_pod_protocol.h"

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace pk {

constexpr uint32_t RUNTIME_ECONOMY_OUTBOX_CAPACITY = 64u;
constexpr uint32_t RUNTIME_ECONOMY_INBOX_CAPACITY = 64u;
constexpr uint32_t RUNTIME_ECONOMY_COMMAND_CAPACITY = 256u;
constexpr uint32_t RUNTIME_ECONOMY_RECEIPT_CAPACITY = 256u;
constexpr uint32_t RUNTIME_ECONOMY_POD_SECTION_MARKER = 0x31504345u; // ECP1

enum class RuntimeEconomyAuthorityMode : uint32_t {
    LEGACY_SYNC = 0,
    POD_ACTIVE_WITH_LEGACY_PARITY = 1,
    POD_ACTIVE = 2,
};

struct RuntimeEconomyWorkerScratch {
    uint32_t stage_index = 0;
    uint32_t stage_cursor = 0;
    bool epoch_active = false;
    bool waiting_for_peer = false;
    bool plan_ready = false;
};

struct RuntimeEconomyIntent {
    uint64_t request_id = 0;
    uint64_t transaction_id = 0;
    uint64_t session_epoch = 0;
    uint64_t economy_generation = 0;
    int64_t effective_day = -1;
    uint16_t target_domain = 0;
    uint16_t opcode = 0;
    uint64_t target_handle = 0;
    int64_t payload0 = 0;
    int64_t payload1 = 0;
};

struct RuntimeEconomyPeerSlot {
    uint64_t request_id = 0;
    uint64_t transaction_id = 0;
    uint64_t session_epoch = 0;
    uint64_t economy_generation = 0;
    uint32_t operation = 0;
    uint8_t occupied = 0;
};

enum class RuntimeEconomyCommandReceiptCode : uint8_t {
    Accepted = 1,
    Pending = 2,
    Committed = 3,
    RejectedAtAdmission = 4,
    RejectedAtExecution = 5,
    Faulted = 6,
};

struct RuntimeEconomyPodCommand {
    uint64_t request_id = 0;
    uint64_t transaction_id = 0;
    uint64_t session_epoch = 0;
    uint64_t economy_generation = 0;
    uint64_t submit_order = 0;
    int32_t opcode = 0;
    int32_t target_cell = -1;
    int64_t target_country = 0;
    int64_t target_cohort = 0;
    int64_t target_building = 0;
    int64_t payload0 = 0;
    int64_t payload1 = 0;
    int64_t payload2 = 0;
};

struct RuntimeEconomyPodReceipt {
    uint64_t request_id = 0;
    uint64_t transaction_id = 0;
    uint64_t session_epoch = 0;
    uint64_t economy_generation = 0;
    int32_t opcode = 0;
    RuntimeEconomyCommandReceiptCode code =
        RuntimeEconomyCommandReceiptCode::Faulted;
    char reason[64]{};
};

using RuntimeEconomyCommittedSnapshot = RuntimeEconomyPodSnapshot;

struct RuntimeEconomyPodReplayReport {
    static constexpr size_t STAGE_COUNT = RUNTIME_ECONOMY_GRAPH_STAGE_COUNT;
    uint32_t completed_stage_mask = 0;
    uint32_t parity_ready_mask = 0;
    uint32_t stage_cursor = 0;
    uint64_t input_hash = 0;
    uint64_t base_hash = 0;
    uint64_t next_hash = 0;
    uint64_t reference_hash = 0;
    uint64_t reference_generation = 0;
    int64_t reference_day = -1;
    std::array<uint64_t, STAGE_COUNT> stage_hash{};
    std::array<uint64_t, STAGE_COUNT> stage_work{};
    std::array<double, STAGE_COUNT> stage_ms{};
    uint8_t input_captured = 0;
    uint8_t committed = 0;
    uint8_t parity_ready = 0;
    uint8_t reference_captured = 0;
    uint8_t parity_compared = 0;
    uint8_t parity_matched = 0;
    uint8_t fatal = 0;
    char fallback_reason[64]{};
    char fatal_reason[64]{};
};

struct RuntimeEconomySnapshotPayload {
    RuntimeEconomyCommittedSnapshot header{};
    uint64_t catalog_hash = 0;
    uint32_t authority_mode = 0;
    uint32_t operation_gate_mask = 0;
    uint32_t pending_receipts = 0;
    uint32_t dirty_family_mask = 0;
    int64_t population_error = 0;
    int64_t money_error = 0;
    int64_t goods_error = 0;
    int64_t summary_population = 0;
    int64_t summary_funds = 0;
    int32_t summary_markets = 0;
    int32_t summary_buildings = 0;
    int32_t summary_cohorts = 0;
    int32_t summary_families = 0;
    char fatal_reason[64]{};
};

// Godot-free POD command mutate adapter. Host ACTIVE always attaches an
// executor; SHADOW self_test may leave it null (Committed-without-mutate).
class EconomyPodCommandExecutor {
public:
    virtual ~EconomyPodCommandExecutor() = default;
    virtual bool apply(const RuntimeEconomyPodCommand &command,
                       std::string &error) = 0;
};

class RuntimeEconomySnapshotRing {
public:
    bool try_begin_write(uint32_t &index);
    RuntimeEconomySnapshotPayload &write_buffer(uint32_t index) {
        return _buffers[index];
    }
    void publish(uint32_t index);
    bool try_acquire_latest(uint64_t after_generation, uint32_t &index);
    const RuntimeEconomySnapshotPayload &read_buffer(uint32_t index) const {
        return _buffers[index];
    }
    void release(uint32_t index);
    void reset();
    uint64_t publish_drop_count() const {
        return _publish_drop_count.load(std::memory_order_relaxed);
    }
    static bool self_test();

private:
    enum BufferState : uint8_t { FREE = 0, WRITING = 1, READY = 2, READING = 3 };
    std::array<RuntimeEconomySnapshotPayload, RUNTIME_SNAPSHOT_RING_SIZE> _buffers{};
    std::array<std::atomic<uint8_t>, RUNTIME_SNAPSHOT_RING_SIZE> _states{};
    std::atomic<uint32_t> _published_index{0};
    std::atomic<uint64_t> _publish_drop_count{0};
};

class RuntimeEconomyPodAuthority {
public:
    RuntimeEconomyPodAuthority();

    void reset() noexcept;
    void set_authority_mode(RuntimeEconomyAuthorityMode mode) noexcept {
        _authority_mode = mode;
    }
    RuntimeEconomyAuthorityMode authority_mode() const noexcept {
        return _authority_mode;
    }
    void attach_stage_ops(EconomyGraphStageOps *ops) noexcept { _stage_ops = ops; }
    void attach_command_executor(EconomyPodCommandExecutor *executor) noexcept {
        _command_executor = executor;
    }
    EconomyGraphStageOps *stage_ops() const noexcept { return _stage_ops; }
    EconomyPodCommandExecutor *command_executor() const noexcept {
        return _command_executor;
    }
    // Sync session/generation watermarks from the attached production runtime.
    void sync_identity(uint64_t session_epoch, uint64_t generation) noexcept;

    bool plan_epoch(const RuntimeEconomyEpochInput &input, std::string &error);
    bool advance_stage(std::string &error);
    bool commit_epoch(std::string &error);
    void discard() noexcept;

    void set_stage_reference(RuntimeEconomyGraphStage stage, int64_t day,
                             uint64_t generation, uint64_t state_hash,
                             uint64_t work_units) noexcept;
    bool snapshot(RuntimeEconomyCommittedSnapshot &out,
                  std::string &error) const;
    bool push_outbox(const RuntimeEconomyPeerSlot &slot, std::string &error);
    bool push_inbox(const RuntimeEconomyPeerSlot &slot, std::string &error);

    bool queue_command(const RuntimeEconomyPodCommand &command,
                       std::string &error);
    bool poll_receipt(RuntimeEconomyPodReceipt &out) noexcept;
    uint32_t pending_command_count() const noexcept {
        return static_cast<uint32_t>(_commands.size());
    }

    // Drain queued POD commands into terminal receipts (Committed or
    // RejectedAtExecution). Idempotent for duplicate request_id.
    void commit_pending_commands() noexcept;

    bool encode_ecp1(std::vector<uint8_t> &out, std::string &error) const;
    bool restore_ecp1(const uint8_t *data, size_t size, std::string &error);

    const RuntimeEconomyPodReplayReport &replay_report() const noexcept {
        return _replay;
    }
    const RuntimeEconomyEpochInput &epoch_input() const noexcept {
        return _input;
    }
    const RuntimeEconomyWorkerScratch &scratch() const noexcept {
        return _scratch;
    }
    uint32_t completed_stage_mask() const noexcept {
        return _completed_stage_mask;
    }
    uint32_t parity_ready_mask() const noexcept { return _parity_ready_mask; }
    uint32_t pending_outbox() const noexcept { return _outbox_count; }
    uint32_t pending_inbox() const noexcept { return _inbox_count; }
    uint32_t operation_gate_mask() const noexcept {
        return _operation_gate_mask;
    }
    void set_operation_gate_mask(uint32_t mask) noexcept {
        _operation_gate_mask = mask;
    }
    void set_business_summary(int64_t population_error, int64_t money_error,
                              int64_t goods_error, int64_t summary_population,
                              int64_t summary_funds, int32_t summary_markets,
                              int32_t summary_buildings, int32_t summary_cohorts,
                              int32_t summary_families) noexcept {
        _committed.population_error = population_error;
        _committed.money_error = money_error;
        _committed.goods_error = goods_error;
        _summary_population = summary_population;
        _summary_funds = summary_funds;
        _summary_markets = summary_markets;
        _summary_buildings = summary_buildings;
        _summary_cohorts = summary_cohorts;
        _summary_families = summary_families;
    }
    bool capture_committed_ledger_state(RuntimeEconomyLedgerState &&state) noexcept;
    const RuntimeEconomyLedgerState &committed_ledger_state() const noexcept {
        return _committed_ledger_state;
    }
    bool epoch_active() const noexcept { return _scratch.epoch_active; }
    bool authority_ready() const noexcept { return _authority_ready; }
    bool fatal() const noexcept { return _replay.fatal != 0; }
    RuntimeEconomySnapshotRing &snapshot_ring() noexcept { return _snapshot_ring; }

    static bool self_test(std::string &error);

private:
    RuntimeEconomyEpochInput _input{};
    RuntimeEconomyWorkerScratch _scratch{};
    RuntimeEconomyPodReplayReport _replay{};
    RuntimeEconomyCommittedSnapshot _committed{};
    RuntimeEconomySnapshotRing _snapshot_ring{};
    EconomyGraphStageOps *_stage_ops = nullptr;
    EconomyPodCommandExecutor *_command_executor = nullptr;
    EconomyStageCursor _stage_cursor{};
    EconomySoAView _view{};
    std::array<RuntimeEconomyPeerSlot, RUNTIME_ECONOMY_OUTBOX_CAPACITY> _outbox{};
    std::array<RuntimeEconomyPeerSlot, RUNTIME_ECONOMY_INBOX_CAPACITY> _inbox{};
    std::array<uint64_t, RUNTIME_ECONOMY_GRAPH_STAGE_COUNT> _reference_hash{};
    std::array<uint64_t, RUNTIME_ECONOMY_GRAPH_STAGE_COUNT> _reference_work{};
    std::array<uint8_t, RUNTIME_ECONOMY_GRAPH_STAGE_COUNT> _reference_present{};
    std::vector<RuntimeEconomyPodCommand> _commands;
    std::vector<RuntimeEconomyPodReceipt> _receipts;
    std::vector<RuntimeEconomyPodReceipt> _terminal_receipts;
    uint32_t _outbox_count = 0;
    uint32_t _inbox_count = 0;
    uint32_t _completed_stage_mask = 0;
    uint32_t _parity_ready_mask = 0;
    uint32_t _operation_gate_mask = 0;
    RuntimeEconomyAuthorityMode _authority_mode =
        RuntimeEconomyAuthorityMode::LEGACY_SYNC;
    uint64_t _generation = 0;
    bool _authority_ready = false;
    int64_t _summary_population = 0;
    int64_t _summary_funds = 0;
    int32_t _summary_markets = 0;
    int32_t _summary_buildings = 0;
    int32_t _summary_cohorts = 0;
    int32_t _summary_families = 0;
    RuntimeEconomyLedgerState _committed_ledger_state;

    bool run_bound_stage(RuntimeEconomyGraphStage stage, std::string &error);
    void publish_replay_stage(RuntimeEconomyGraphStage stage, uint64_t work,
                              uint64_t stage_hash, double ms) noexcept;
    static uint64_t hash_mix(uint64_t current, uint64_t value) noexcept;
    static uint64_t hash_input(const RuntimeEconomyEpochInput &input) noexcept;
};

} // namespace pk

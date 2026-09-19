#pragma once

#include "economy_graph_kernels.h"
#include "runtime_economy_state.h"
#include "runtime_domain_pod.h"
#include "runtime_economy_ecp2.h"
#include "runtime_pod_protocol.h"

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

namespace pk {

class NativeEconomyRuntime;

constexpr uint32_t RUNTIME_ECONOMY_OUTBOX_CAPACITY = 64u;
constexpr uint32_t RUNTIME_ECONOMY_INBOX_CAPACITY = 64u;
constexpr uint32_t RUNTIME_ECONOMY_COMMAND_CAPACITY = 256u;
constexpr uint32_t RUNTIME_ECONOMY_RECEIPT_CAPACITY = 256u;
constexpr uint32_t RUNTIME_ECONOMY_POD_SECTION_MARKER = 0x31504345u; // ECP1
// ECP1 ABI versions: 1 header/receipts, 2 summaries, 3 authority mode,
// 4 committed ledger core, 5 + handle generation / market signal columns,
// 6 + reservations / population diagnostics, 7 + building / trade-escrow
// opaque committed payloads (PKEC-shaped blobs), 8 + family/person opaque
// committed payloads, 9 + resource snapshot / epoch-cursor opaque payloads.

enum EconomyPodMirrorFeature : uint32_t {
    ECONOMY_POD_MIRROR_COHORT_CORE = 1u << 0,
    ECONOMY_POD_MIRROR_MARKET_CORE = 1u << 1,
    ECONOMY_POD_MIRROR_COHORT_GENERATION = 1u << 2,
    ECONOMY_POD_MIRROR_MARKET_SIGNALS = 1u << 3,
    ECONOMY_POD_MIRROR_RESERVATIONS = 1u << 4,
    ECONOMY_POD_MIRROR_POPULATION_DIAGNOSTICS = 1u << 5,
    ECONOMY_POD_MIRROR_BUILDING = 1u << 6,
    ECONOMY_POD_MIRROR_TRADE_ESCROW = 1u << 7,
    ECONOMY_POD_MIRROR_FAMILY = 1u << 8,
    ECONOMY_POD_MIRROR_RESOURCE = 1u << 9,
    ECONOMY_POD_MIRROR_EPOCH_CURSOR = 1u << 10,
};

constexpr uint32_t ECONOMY_POD_MIRROR_PHASE21 =
    ECONOMY_POD_MIRROR_COHORT_CORE | ECONOMY_POD_MIRROR_MARKET_CORE |
    ECONOMY_POD_MIRROR_COHORT_GENERATION | ECONOMY_POD_MIRROR_MARKET_SIGNALS;

constexpr uint32_t ECONOMY_POD_MIRROR_PHASE22 =
    ECONOMY_POD_MIRROR_PHASE21 | ECONOMY_POD_MIRROR_RESERVATIONS |
    ECONOMY_POD_MIRROR_POPULATION_DIAGNOSTICS;

constexpr uint32_t ECONOMY_POD_MIRROR_PHASE23 =
    ECONOMY_POD_MIRROR_PHASE22 | ECONOMY_POD_MIRROR_BUILDING |
    ECONOMY_POD_MIRROR_TRADE_ESCROW;

constexpr uint32_t ECONOMY_POD_MIRROR_PHASE232 =
    ECONOMY_POD_MIRROR_PHASE23 | ECONOMY_POD_MIRROR_FAMILY;

constexpr uint32_t ECONOMY_POD_MIRROR_PHASE233 =
    ECONOMY_POD_MIRROR_PHASE232 | ECONOMY_POD_MIRROR_RESOURCE |
    ECONOMY_POD_MIRROR_EPOCH_CURSOR;

constexpr uint32_t ECONOMY_POD_MIRROR_REQUIRED_FOR_ACTIVE =
    ECONOMY_POD_MIRROR_PHASE233;

enum class RuntimeEconomyAuthorityMode : uint32_t {
    LEGACY_SYNC = 0,
    POD_ACTIVE_WITH_LEGACY_PARITY = 1,
    POD_ACTIVE = 2,
};

// Production execution policy for the Economy domain (Phase-1 dedup).
// Orthogonal to RuntimeEconomyAuthorityMode (POD vs legacy ledger writer).
// ACTIVE_ONLY: worker compact-slice production; SHADOW StageOps work = 0.
// ACTIVE_WITH_PARITY: production + explicit SHADOW StageOps hash probe.
// LEGACY_ONLY: main-thread sync ECONOMY_GRAPH only; no worker production attach.
enum class EconomyExecutionMode : uint32_t {
    ACTIVE_ONLY = 0,
    ACTIVE_WITH_PARITY = 1,
    LEGACY_ONLY = 2,
};

inline const char *economy_execution_mode_name(EconomyExecutionMode mode) noexcept {
    switch (mode) {
    case EconomyExecutionMode::ACTIVE_WITH_PARITY:
        return "ACTIVE_WITH_PARITY";
    case EconomyExecutionMode::LEGACY_ONLY:
        return "LEGACY_ONLY";
    case EconomyExecutionMode::ACTIVE_ONLY:
    default:
        return "ACTIVE_ONLY";
    }
}

inline bool parse_economy_execution_mode(const char *text,
                                         EconomyExecutionMode &out) noexcept {
    if (text == nullptr || text[0] == '\0') {
        out = EconomyExecutionMode::ACTIVE_ONLY;
        return true;
    }
    if (std::strcmp(text, "ACTIVE_ONLY") == 0) {
        out = EconomyExecutionMode::ACTIVE_ONLY;
        return true;
    }
    if (std::strcmp(text, "ACTIVE_WITH_PARITY") == 0) {
        out = EconomyExecutionMode::ACTIVE_WITH_PARITY;
        return true;
    }
    if (std::strcmp(text, "LEGACY_ONLY") == 0) {
        out = EconomyExecutionMode::LEGACY_ONLY;
        return true;
    }
    return false;
}

// Phase-2.4.2: which path mutates NativeEconomyRuntime on ACTIVE days.
// Orthogonal to EconomyExecutionMode and RuntimeEconomyAuthorityMode.
// COMPACT_SLICE (default): Host worker_run_compact_slice loop.
// STAGE_OPS: reserved; refused until StageOps bounded advance lands (P2.4.3+).
enum class EconomyProductionWriter : uint32_t {
    COMPACT_SLICE = 0,
    STAGE_OPS = 1,
};

inline const char *economy_production_writer_name(
        EconomyProductionWriter writer) noexcept {
    switch (writer) {
    case EconomyProductionWriter::STAGE_OPS:
        return "stage_ops";
    case EconomyProductionWriter::COMPACT_SLICE:
    default:
        return "compact_slice";
    }
}

inline bool parse_economy_production_writer(const char *text,
                                            EconomyProductionWriter &out) noexcept {
    if (text == nullptr || text[0] == '\0') {
        out = EconomyProductionWriter::COMPACT_SLICE;
        return true;
    }
    if (std::strcmp(text, "compact_slice") == 0) {
        out = EconomyProductionWriter::COMPACT_SLICE;
        return true;
    }
    if (std::strcmp(text, "stage_ops") == 0) {
        out = EconomyProductionWriter::STAGE_OPS;
        return true;
    }
    return false;
}

// Phase-2.4.4.1 / 2.4.5: checklist for economy_production_writer=stage_ops.
// P2.4.4.3 sets all four bits (0xF). Host start still fail-closes on
// parity_conflict / requires_mutate / missing readiness bits.
constexpr uint32_t ECONOMY_STAGE_OPS_READY_PRELUDE = 1u << 0;
constexpr uint32_t ECONOMY_STAGE_OPS_READY_COMMIT_DRAINS = 1u << 1;
constexpr uint32_t ECONOMY_STAGE_OPS_READY_BOUNDED_KERNELS = 1u << 2;
constexpr uint32_t ECONOMY_STAGE_OPS_READY_HOST_LOOP = 1u << 3;
constexpr uint32_t ECONOMY_STAGE_OPS_READY_REQUIRED_FOR_WRITER =
    ECONOMY_STAGE_OPS_READY_PRELUDE | ECONOMY_STAGE_OPS_READY_COMMIT_DRAINS |
    ECONOMY_STAGE_OPS_READY_BOUNDED_KERNELS | ECONOMY_STAGE_OPS_READY_HOST_LOOP;

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
    void initialize_state(int32_t cells, int32_t goods) {
        _state.clear(cells, goods);
    }
    RuntimeEconomyOwnedState &state() noexcept { return _state; }
    const RuntimeEconomyOwnedState &state() const noexcept { return _state; }
    bool state_initialized() const noexcept {
        return _state.market.market_count > 0 &&
            _state.market.good_count > 0 &&
            _state.population.cell_first_page.size() ==
                static_cast<size_t>(_state.market.market_count);
    }
    uint64_t state_hash() const noexcept;
    bool import_and_publish_committed_ledger(RuntimeEconomyLedgerState &&ledger,
                                            std::string &error);
    bool import_committed_ledger(const RuntimeEconomyLedgerState &ledger,
                                 std::string &error);
    bool export_committed_ledger(RuntimeEconomyLedgerState &ledger,
                                 std::string &error) const;
    // N10 Owned identity export. When NativeEconomyRuntime is formula-bound,
    // `_state` IS the runtime's live state, so `import_committed_ledger` would
    // replace the very object the bind aliases. This republishes the committed
    // snapshot from the live `_state` instead: export, stamp the runtime's
    // committed generation / day, and capture. Live population, market,
    // building and domain stores are never replaced.
    bool publish_owned_committed_mirror(uint64_t generation,
                                        int64_t committed_day,
                                        std::string &error);
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

    // Phase-2.6.3: opcodes 1–23 mutate OwnedState SoA first under POD_ACTIVE.
    static bool is_owned_core_opcode(int32_t opcode) noexcept;
    static bool is_owned_command_opcode(int32_t opcode) noexcept {
        return is_owned_core_opcode(opcode);
    }
    static bool is_owned_heavy_pod_opcode(int32_t opcode) noexcept;
    // Applies opcode 1–23 to `_state`. Caller must be POD_ACTIVE with an
    // initialized owned state; returns settled amount.
    bool try_apply_owned_core_command(const RuntimeEconomyPodCommand &command,
                                      std::string &error,
                                      int64_t &settled_out) noexcept;

    bool plan_epoch(const RuntimeEconomyEpochInput &input, std::string &error);
    bool advance_stage(std::string &error);
    bool commit_epoch(std::string &error);
    uint32_t planned_stage_index() const noexcept { return _scratch.stage_index; }
    bool planned_epoch_active() const noexcept { return _scratch.epoch_active; }
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
    // Returns the number of commands that mutated via the attached executor
    // (Phase-2.6.2: host recaptures the committed mirror when > 0).
    uint32_t commit_pending_commands() noexcept;

    bool encode_ecp1(std::vector<uint8_t> &out, std::string &error) const;
    bool restore_ecp1(const uint8_t *data, size_t size, std::string &error);
    bool encode_ecp2(const RuntimeEconomyEcp2State &state,
                     std::vector<uint8_t> &out, std::string &error) const;
    bool encode_ecp2(std::vector<uint8_t> &out, std::string &error) const;
    bool restore_ecp2(const uint8_t *data, size_t size, std::string &error);
    bool capture_ecp2_from_runtime(NativeEconomyRuntime &runtime,
                                   uint32_t flags, std::string &error);
    const RuntimeEconomyEcp2State &ecp2_state() const noexcept { return _ecp2; }

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
    // Features currently present in the committed ledger / owned mirror.
    uint32_t mirror_feature_mask() const noexcept {
        return _published_mirror_features.load(std::memory_order_acquire);
    }
    // True only when every feature in ECONOMY_POD_MIRROR_REQUIRED_FOR_ACTIVE
    // is present (Phase-2.3.3 completes the committed mirror feature set).
    bool pod_active_ready() const noexcept {
        return (mirror_feature_mask() & ECONOMY_POD_MIRROR_REQUIRED_FOR_ACTIVE) ==
               ECONOMY_POD_MIRROR_REQUIRED_FOR_ACTIVE;
    }
    uint32_t committed_ledger_abi() const noexcept {
        const uint32_t mask = mirror_feature_mask();
        if (mask == 0) return 3u;
        if ((mask & (ECONOMY_POD_MIRROR_RESOURCE | ECONOMY_POD_MIRROR_EPOCH_CURSOR)) ==
            (ECONOMY_POD_MIRROR_RESOURCE | ECONOMY_POD_MIRROR_EPOCH_CURSOR)) return 9u;
        if ((mask & ECONOMY_POD_MIRROR_FAMILY) != 0) return 8u;
        if ((mask & (ECONOMY_POD_MIRROR_BUILDING | ECONOMY_POD_MIRROR_TRADE_ESCROW)) ==
            (ECONOMY_POD_MIRROR_BUILDING | ECONOMY_POD_MIRROR_TRADE_ESCROW)) return 7u;
        if ((mask & ECONOMY_POD_MIRROR_RESERVATIONS) != 0) return 6u;
        return (mask & ECONOMY_POD_MIRROR_COHORT_GENERATION) != 0 ? 5u : 4u;
    }
    bool epoch_active() const noexcept { return _scratch.epoch_active; }
    bool authority_ready() const noexcept { return _authority_ready; }
    bool fatal() const noexcept { return _replay.fatal != 0; }
    RuntimeEconomySnapshotRing &snapshot_ring() noexcept { return _snapshot_ring; }

    static bool self_test(std::string &error);

private:
    RuntimeEconomyOwnedState _state;
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
    // 私有导出缓冲复用上一代容量；验证失败不得修改已发布账本。
    RuntimeEconomyLedgerState _export_ledger_scratch;
    // 读报告只取发布标量，不遍历 worker 正在替换的账本容器。
    std::atomic<uint32_t> _published_mirror_features{0};
    void publish_mirror_features() noexcept;
    RuntimeEconomyEcp2State _ecp2{};

    bool run_bound_stage(RuntimeEconomyGraphStage stage, std::string &error);
    void publish_replay_stage(RuntimeEconomyGraphStage stage, uint64_t work,
                              uint64_t stage_hash, double ms) noexcept;
    static uint64_t hash_mix(uint64_t current, uint64_t value) noexcept;
    static uint64_t hash_input(const RuntimeEconomyEpochInput &input) noexcept;
};

} // namespace pk

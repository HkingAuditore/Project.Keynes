#include "runtime_economy_pod.h"

#include <algorithm>
#include <chrono>
#include <cstring>

namespace pk {
namespace {

constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;

void copy_reason(char *dst, size_t capacity, const char *reason) {
    if (capacity == 0) return;
    size_t i = 0;
    if (reason != nullptr) {
        for (; i + 1 < capacity && reason[i] != '\0'; ++i) dst[i] = reason[i];
    }
    dst[i] = '\0';
}

double elapsed_ms(std::chrono::steady_clock::time_point begin) {
    return std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now() - begin).count();
}

void append_u32(std::vector<uint8_t> &out, uint32_t value) {
    out.push_back(static_cast<uint8_t>(value & 0xffu));
    out.push_back(static_cast<uint8_t>((value >> 8) & 0xffu));
    out.push_back(static_cast<uint8_t>((value >> 16) & 0xffu));
    out.push_back(static_cast<uint8_t>((value >> 24) & 0xffu));
}

void append_u64(std::vector<uint8_t> &out, uint64_t value) {
    for (int i = 0; i < 8; ++i)
        out.push_back(static_cast<uint8_t>((value >> (8 * i)) & 0xffu));
}

void append_i64(std::vector<uint8_t> &out, int64_t value) {
    append_u64(out, static_cast<uint64_t>(value));
}

void append_i32(std::vector<uint8_t> &out, int32_t value) {
    append_u32(out, static_cast<uint32_t>(value));
}

bool read_u32(const uint8_t *&p, const uint8_t *end, uint32_t &value) {
    if (end - p < 4) return false;
    value = static_cast<uint32_t>(p[0]) |
        (static_cast<uint32_t>(p[1]) << 8) |
        (static_cast<uint32_t>(p[2]) << 16) |
        (static_cast<uint32_t>(p[3]) << 24);
    p += 4;
    return true;
}

bool read_u64(const uint8_t *&p, const uint8_t *end, uint64_t &value) {
    if (end - p < 8) return false;
    value = 0;
    for (int i = 0; i < 8; ++i)
        value |= static_cast<uint64_t>(p[i]) << (8 * i);
    p += 8;
    return true;
}

bool read_i64(const uint8_t *&p, const uint8_t *end, int64_t &value) {
    uint64_t raw = 0;
    if (!read_u64(p, end, raw)) return false;
    value = static_cast<int64_t>(raw);
    return true;
}

bool read_i32(const uint8_t *&p, const uint8_t *end, int32_t &value) {
    uint32_t raw = 0;
    if (!read_u32(p, end, raw)) return false;
    value = static_cast<int32_t>(raw);
    return true;
}

uint64_t fnv1a(const uint8_t *data, size_t size) noexcept {
    uint64_t hash = FNV_OFFSET;
    for (size_t i = 0; i < size; ++i) {
        hash ^= data[i];
        hash *= FNV_PRIME;
    }
    return hash;
}

} // namespace

bool RuntimeEconomySnapshotRing::try_begin_write(uint32_t &index) {
    for (uint32_t i = 0; i < RUNTIME_SNAPSHOT_RING_SIZE; ++i) {
        uint8_t expected = FREE;
        if (_states[i].compare_exchange_strong(
                expected, WRITING, std::memory_order_acq_rel)) {
            index = i;
            return true;
        }
    }
    for (uint32_t i = 0; i < RUNTIME_SNAPSHOT_RING_SIZE; ++i) {
        uint8_t expected = READY;
        if (_states[i].compare_exchange_strong(
                expected, WRITING, std::memory_order_acq_rel)) {
            index = i;
            _publish_drop_count.fetch_add(1, std::memory_order_relaxed);
            return true;
        }
    }
    return false;
}

void RuntimeEconomySnapshotRing::publish(uint32_t index) {
    if (index >= RUNTIME_SNAPSHOT_RING_SIZE) return;
    _states[index].store(READY, std::memory_order_release);
    _published_index.store(index, std::memory_order_release);
}

bool RuntimeEconomySnapshotRing::try_acquire_latest(uint64_t after_generation,
                                                    uint32_t &index) {
    const uint32_t published =
        _published_index.load(std::memory_order_acquire);
    if (published >= RUNTIME_SNAPSHOT_RING_SIZE) return false;
    uint8_t expected = READY;
    if (!_states[published].compare_exchange_strong(
            expected, READING, std::memory_order_acq_rel)) {
        return false;
    }
    if (_buffers[published].header.generation <= after_generation) {
        _states[published].store(READY, std::memory_order_release);
        return false;
    }
    index = published;
    return true;
}

void RuntimeEconomySnapshotRing::release(uint32_t index) {
    if (index >= RUNTIME_SNAPSHOT_RING_SIZE) return;
    _states[index].store(READY, std::memory_order_release);
}

void RuntimeEconomySnapshotRing::reset() {
    for (auto &state : _states) state.store(FREE, std::memory_order_release);
    _published_index.store(0, std::memory_order_release);
    _publish_drop_count.store(0, std::memory_order_release);
    _buffers = {};
}

bool RuntimeEconomySnapshotRing::self_test() {
    RuntimeEconomySnapshotRing ring;
    uint32_t index = 0;
    if (!ring.try_begin_write(index)) return false;
    ring.write_buffer(index).header.generation = 7;
    ring.write_buffer(index).header.committed = true;
    ring.publish(index);
    uint32_t read_index = 0;
    if (!ring.try_acquire_latest(0, read_index)) return false;
    if (ring.read_buffer(read_index).header.generation != 7) return false;
    ring.release(read_index);
    return true;
}

RuntimeEconomyPodAuthority::RuntimeEconomyPodAuthority() {
    reset();
}

void RuntimeEconomyPodAuthority::reset() noexcept {
    _input = RuntimeEconomyEpochInput{};
    _scratch = RuntimeEconomyWorkerScratch{};
    _replay = RuntimeEconomyPodReplayReport{};
    _committed = RuntimeEconomyCommittedSnapshot{};
    _snapshot_ring.reset();
    _stage_cursor = EconomyStageCursor{};
    _view = EconomySoAView{};
    _outbox = {};
    _inbox = {};
    _reference_hash = {};
    _reference_work = {};
    _reference_present = {};
    _commands.clear();
    _receipts.clear();
    _terminal_receipts.clear();
    _commands.reserve(RUNTIME_ECONOMY_COMMAND_CAPACITY);
    _receipts.reserve(RUNTIME_ECONOMY_RECEIPT_CAPACITY);
    _terminal_receipts.reserve(RUNTIME_ECONOMY_RECEIPT_CAPACITY);
    _outbox_count = 0;
    _inbox_count = 0;
    _completed_stage_mask = 0;
    _parity_ready_mask = 0;
    _operation_gate_mask = 0;
    _generation = 0;
    _authority_ready = false;
    _summary_population = 0;
    _summary_funds = 0;
    _summary_markets = 0;
    _summary_buildings = 0;
    _summary_cohorts = 0;
    _summary_families = 0;
    // Keep _stage_ops / _command_executor: Host re-attaches identity separately.
}

void RuntimeEconomyPodAuthority::sync_identity(uint64_t session_epoch,
                                                 uint64_t generation) noexcept {
    if (session_epoch != 0) _input.session_epoch = session_epoch;
    _generation = generation;
    if (generation != 0) _input.economy_generation = generation;
}

uint64_t RuntimeEconomyPodAuthority::hash_mix(uint64_t current,
                                              uint64_t value) noexcept {
    current ^= value;
    current *= FNV_PRIME;
    return current;
}

uint64_t RuntimeEconomyPodAuthority::hash_input(
        const RuntimeEconomyEpochInput &input) noexcept {
    uint64_t hash = FNV_OFFSET;
    hash = hash_mix(hash, static_cast<uint64_t>(input.sample_day));
    hash = hash_mix(hash, input.session_epoch);
    hash = hash_mix(hash, input.economy_generation);
    hash = hash_mix(hash, input.input_generation);
    hash = hash_mix(hash, input.country_generation);
    hash = hash_mix(hash, input.catalog_hash);
    hash = hash_mix(hash, input.policy_hash);
    hash = hash_mix(hash, input.environment_shape_hash);
    hash = hash_mix(hash, input.cell_count);
    return hash;
}

bool RuntimeEconomyPodAuthority::plan_epoch(const RuntimeEconomyEpochInput &input,
                                            std::string &error) {
    error.clear();
    if (!input.valid || input.sample_day < 0 || input.cell_count == 0 ||
        input.input_generation == 0) {
        error = "economy_pod_epoch_input_invalid";
        return false;
    }
    if (_scratch.epoch_active || _scratch.waiting_for_peer) {
        error = "economy_pod_epoch_busy";
        return false;
    }
    _input = input;
    _scratch = RuntimeEconomyWorkerScratch{};
    _scratch.epoch_active = true;
    _scratch.plan_ready = true;
    _stage_cursor = EconomyStageCursor{};
    _completed_stage_mask = 0;
    _parity_ready_mask = 0;
    _authority_ready = false;
    _replay = RuntimeEconomyPodReplayReport{};
    _replay.input_hash = hash_input(input);
    _replay.base_hash = hash_mix(FNV_OFFSET, _generation);
    _replay.input_captured = 1;
    if (_stage_ops != nullptr) {
        std::string bind_error;
        if (!_stage_ops->bind_view(_view, bind_error)) {
            error = bind_error.empty() ? "economy_pod_bind_view_failed"
                                       : bind_error;
            return false;
        }
    }
    return true;
}

void RuntimeEconomyPodAuthority::publish_replay_stage(
        RuntimeEconomyGraphStage stage, uint64_t work, uint64_t stage_hash,
        double ms) noexcept {
    const size_t index = static_cast<size_t>(stage);
    if (index >= RuntimeEconomyPodReplayReport::STAGE_COUNT) return;
    _replay.stage_work[index] = work;
    _replay.stage_hash[index] = stage_hash;
    _replay.stage_ms[index] = ms;
    _replay.completed_stage_mask |= runtime_economy_graph_stage_bit(stage);
    _replay.stage_cursor = static_cast<uint32_t>(
        std::max<uint64_t>(_replay.stage_cursor, work));
    _completed_stage_mask = _replay.completed_stage_mask;
    _replay.next_hash = stage_hash;

    if (_reference_present[index] != 0) {
        _replay.reference_captured = 1;
        _replay.reference_hash = _reference_hash[index];
        _replay.parity_compared = 1;
        const bool matched =
            _reference_hash[index] == stage_hash &&
            _reference_work[index] == work;
        _replay.parity_matched = matched ? 1 : 0;
        if (matched && _stage_ops != nullptr) {
            _parity_ready_mask |= runtime_economy_graph_stage_bit(stage);
        }
        _replay.parity_ready_mask = _parity_ready_mask;
        _replay.parity_ready =
            (_parity_ready_mask == RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK) ? 1 : 0;
    }
}

bool RuntimeEconomyPodAuthority::run_bound_stage(RuntimeEconomyGraphStage stage,
                                                 std::string &error) {
    error.clear();
    const auto begin = std::chrono::steady_clock::now();
    EconomyStageResult result;
    if (_stage_ops != nullptr) {
        if (!economy_kernel_run_stage(*_stage_ops, stage, _stage_cursor, _input,
                                      result, error)) {
            if (result.fatal) {
                _replay.fatal = 1;
                copy_reason(_replay.fatal_reason, sizeof(_replay.fatal_reason),
                            result.fatal_reason[0] != '\0' ? result.fatal_reason
                                                          : error.c_str());
            }
            return false;
        }
        publish_replay_stage(stage, result.work_units, result.state_hash,
                             elapsed_ms(begin));
        _scratch.stage_cursor = static_cast<uint32_t>(result.work_units);
        return true;
    }

    // Hash-boundary fallback when StageOps is not attached (diagnostic only).
    const uint64_t work = _input.cell_count;
    uint64_t stage_hash = hash_mix(
        _replay.next_hash != 0 ? _replay.next_hash : _replay.input_hash,
        runtime_economy_graph_stage_bit(stage));
    stage_hash = hash_mix(stage_hash, work);
    stage_hash = hash_mix(stage_hash, _input.catalog_hash);
    publish_replay_stage(stage, work, stage_hash, elapsed_ms(begin));
    _scratch.stage_cursor = static_cast<uint32_t>(work);
    return true;
}

bool RuntimeEconomyPodAuthority::advance_stage(std::string &error) {
    error.clear();
    if (!_scratch.epoch_active || !_scratch.plan_ready) {
        error = "economy_pod_epoch_not_planned";
        return false;
    }
    if (_scratch.waiting_for_peer) {
        error = "economy_pod_waiting_for_peer";
        return false;
    }
    if (_scratch.stage_index >= RUNTIME_ECONOMY_GRAPH_STAGE_COUNT) {
        error = "economy_pod_stages_exhausted";
        return false;
    }
    const auto stage =
        static_cast<RuntimeEconomyGraphStage>(_scratch.stage_index);
    if (!run_bound_stage(stage, error)) {
        copy_reason(_replay.fallback_reason, sizeof(_replay.fallback_reason),
                    error.c_str());
        return false;
    }
    ++_scratch.stage_index;
    _stage_cursor.stage_index = _scratch.stage_index;
    return true;
}

bool RuntimeEconomyPodAuthority::commit_epoch(std::string &error) {
    error.clear();
    if (!_scratch.epoch_active || !_scratch.plan_ready) {
        error = "economy_pod_epoch_not_planned";
        return false;
    }
    if (_scratch.stage_index != RUNTIME_ECONOMY_GRAPH_STAGE_COUNT ||
        _completed_stage_mask != RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK) {
        error = "economy_pod_stages_incomplete";
        return false;
    }
    if (_outbox_count != 0 || _inbox_count != 0 || _scratch.waiting_for_peer) {
        error = "economy_pod_peer_queues_busy";
        return false;
    }
    if (_replay.fatal != 0) {
        error = "economy_pod_fatal";
        return false;
    }
    ++_generation;
    _committed = RuntimeEconomyCommittedSnapshot{};
    _committed.session_epoch = _input.session_epoch;
    _committed.generation = _generation;
    _committed.committed_day = _input.sample_day;
    _committed.from_day = _input.sample_day > 0 ? _input.sample_day - 1 : -1;
    _committed.epoch_sample_day = _input.sample_day;
    _committed.input_generation = _input.input_generation;
    _committed.country_generation = _input.country_generation;
    _committed.completed_stage_mask = _completed_stage_mask;
    _committed.pending_outbox = 0;
    _committed.pending_inbox = 0;
    _committed.operation_gate_mask = _operation_gate_mask;
    _committed.committed = true;
    _committed.authority_ready =
        _parity_ready_mask == RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK;
    _committed.state_hash = hash_mix(_replay.next_hash, _generation);
    _committed.state_hash = hash_mix(_committed.state_hash,
        static_cast<uint64_t>(_committed.committed_day));
    _committed.state_hash = hash_mix(_committed.state_hash,
        _committed.completed_stage_mask);
    _committed.population_error = 0;
    _committed.money_error = 0;
    _committed.goods_error = 0;

    uint32_t ring_index = 0;
    if (_snapshot_ring.try_begin_write(ring_index)) {
        RuntimeEconomySnapshotPayload &payload =
            _snapshot_ring.write_buffer(ring_index);
        payload = RuntimeEconomySnapshotPayload{};
        payload.header = _committed;
        payload.catalog_hash = _input.catalog_hash;
        payload.operation_gate_mask = _operation_gate_mask;
        payload.pending_receipts = static_cast<uint32_t>(_receipts.size());
        _snapshot_ring.publish(ring_index);
    }

    // Promote pending receipts that reached the committed boundary.
    commit_pending_commands();

    _replay.committed = 1;
    _replay.next_hash = _committed.state_hash;
    _replay.parity_ready_mask = _parity_ready_mask;
    _replay.parity_ready =
        (_parity_ready_mask == RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK) ? 1 : 0;
    _scratch.epoch_active = false;
    _scratch.plan_ready = false;
    _authority_ready = _committed.authority_ready;
    return true;
}

void RuntimeEconomyPodAuthority::discard() noexcept {
    _scratch = RuntimeEconomyWorkerScratch{};
    _completed_stage_mask = 0;
    _authority_ready = false;
    copy_reason(_replay.fallback_reason, sizeof(_replay.fallback_reason),
                "economy_pod_discarded");
}

void RuntimeEconomyPodAuthority::set_stage_reference(
        RuntimeEconomyGraphStage stage, int64_t day, uint64_t generation,
        uint64_t state_hash, uint64_t work_units) noexcept {
    const size_t index = static_cast<size_t>(stage);
    if (index >= RUNTIME_ECONOMY_GRAPH_STAGE_COUNT) return;
    _reference_present[index] = 1;
    _reference_hash[index] = state_hash;
    _reference_work[index] = work_units;
    _replay.reference_day = day;
    _replay.reference_generation = generation;
    _replay.reference_hash = state_hash;
    _replay.reference_captured = 1;
}

bool RuntimeEconomyPodAuthority::snapshot(RuntimeEconomyCommittedSnapshot &out,
                                          std::string &error) const {
    error.clear();
    if (!_committed.committed || _scratch.epoch_active) {
        error = "economy_pod_snapshot_not_committed";
        return false;
    }
    out = _committed;
    out.pending_outbox = _outbox_count;
    out.pending_inbox = _inbox_count;
    return true;
}

bool RuntimeEconomyPodAuthority::push_outbox(const RuntimeEconomyPeerSlot &slot,
                                             std::string &error) {
    error.clear();
    if (_outbox_count >= RUNTIME_ECONOMY_OUTBOX_CAPACITY) {
        error = "economy_pod_outbox_full";
        return false;
    }
    if (slot.request_id == 0) {
        error = "economy_pod_outbox_identity_invalid";
        return false;
    }
    _outbox[_outbox_count++] = slot;
    _outbox[_outbox_count - 1u].occupied = 1;
    return true;
}

bool RuntimeEconomyPodAuthority::push_inbox(const RuntimeEconomyPeerSlot &slot,
                                            std::string &error) {
    error.clear();
    if (_inbox_count >= RUNTIME_ECONOMY_INBOX_CAPACITY) {
        error = "economy_pod_inbox_full";
        return false;
    }
    if (slot.request_id == 0) {
        error = "economy_pod_inbox_identity_invalid";
        return false;
    }
    _inbox[_inbox_count++] = slot;
    _inbox[_inbox_count - 1u].occupied = 1;
    return true;
}

bool RuntimeEconomyPodAuthority::queue_command(
        const RuntimeEconomyPodCommand &command, std::string &error) {
    error.clear();
    if (command.request_id == 0) {
        error = "economy_pod_command_identity_invalid";
        return false;
    }
    for (const RuntimeEconomyPodReceipt &terminal : _terminal_receipts) {
        if (terminal.request_id == command.request_id) {
            _receipts.push_back(terminal);
            return true;
        }
    }
    for (const RuntimeEconomyPodReceipt &pending : _receipts) {
        if (pending.request_id == command.request_id) {
            _receipts.push_back(pending);
            return true;
        }
    }
    auto reject_admission = [&](const char *reason) {
        RuntimeEconomyPodReceipt rejected;
        rejected.request_id = command.request_id;
        rejected.transaction_id = command.transaction_id;
        rejected.session_epoch = command.session_epoch;
        rejected.economy_generation = command.economy_generation;
        rejected.opcode = command.opcode;
        rejected.code = RuntimeEconomyCommandReceiptCode::RejectedAtAdmission;
        copy_reason(rejected.reason, sizeof(rejected.reason), reason);
        _receipts.push_back(rejected);
        _terminal_receipts.push_back(rejected);
        return true;
    };
    // Phase 4: admit only legacy opcodes 1..23.
    if (command.opcode < 1 || command.opcode > 23) {
        return reject_admission("economy_command_opcode_out_of_range");
    }
    if (command.session_epoch != 0 && _input.session_epoch != 0 &&
        command.session_epoch != _input.session_epoch) {
        return reject_admission("economy_command_session_mismatch");
    }
    if (_generation != 0 && command.economy_generation != 0 &&
        command.economy_generation != _generation) {
        return reject_admission("economy_command_generation_mismatch");
    }
    if (_commands.size() >= RUNTIME_ECONOMY_COMMAND_CAPACITY) {
        error = "economy_pod_command_queue_full";
        return false;
    }
    _commands.push_back(command);
    RuntimeEconomyPodReceipt accepted;
    accepted.request_id = command.request_id;
    accepted.transaction_id = command.transaction_id;
    accepted.session_epoch = command.session_epoch;
    accepted.economy_generation = command.economy_generation;
    accepted.opcode = command.opcode;
    accepted.code = RuntimeEconomyCommandReceiptCode::Accepted;
    copy_reason(accepted.reason, sizeof(accepted.reason), "accepted");
    _receipts.push_back(accepted);
    return true;
}

void RuntimeEconomyPodAuthority::commit_pending_commands() noexcept {
    std::vector<RuntimeEconomyPodReceipt> committed_now;
    committed_now.reserve(_commands.size());
    for (const RuntimeEconomyPodCommand &command : _commands) {
        RuntimeEconomyPodReceipt *existing = nullptr;
        for (RuntimeEconomyPodReceipt &terminal : _terminal_receipts) {
            if (terminal.request_id == command.request_id) {
                existing = &terminal;
                break;
            }
        }
        if (existing != nullptr) {
            committed_now.push_back(*existing);
            continue;
        }

        RuntimeEconomyPodReceipt receipt;
        receipt.request_id = command.request_id;
        receipt.transaction_id = command.transaction_id;
        receipt.session_epoch = command.session_epoch;
        receipt.economy_generation = command.economy_generation;
        receipt.opcode = command.opcode;
        // Opcode 20 = COMMAND_BUILD_CANAL: requires a quote token in payload0.
        if (command.opcode == 20 && command.payload0 == 0) {
            receipt.code = RuntimeEconomyCommandReceiptCode::RejectedAtExecution;
            copy_reason(receipt.reason, sizeof(receipt.reason),
                        "economy_command_build_canal_token_missing");
        } else if (_command_executor != nullptr) {
            std::string apply_error;
            if (_command_executor->apply(command, apply_error)) {
                receipt.code = RuntimeEconomyCommandReceiptCode::Committed;
                copy_reason(receipt.reason, sizeof(receipt.reason), "committed");
            } else {
                receipt.code =
                    RuntimeEconomyCommandReceiptCode::RejectedAtExecution;
                copy_reason(receipt.reason, sizeof(receipt.reason),
                            apply_error.empty()
                                ? "economy_command_apply_failed"
                                : apply_error.c_str());
            }
        } else {
            // No executor: SHADOW self_test keeps Committed-without-mutate.
            receipt.code = RuntimeEconomyCommandReceiptCode::Committed;
            copy_reason(receipt.reason, sizeof(receipt.reason), "committed");
        }
        _terminal_receipts.push_back(receipt);
        committed_now.push_back(receipt);
    }
    _commands.clear();
    // Replace admission receipts with terminal outcomes for this commit.
    _receipts = std::move(committed_now);
}

bool RuntimeEconomyPodAuthority::poll_receipt(
        RuntimeEconomyPodReceipt &out) noexcept {
    if (_receipts.empty()) return false;
    out = _receipts.front();
    _receipts.erase(_receipts.begin());
    return true;
}

bool RuntimeEconomyPodAuthority::encode_ecp1(std::vector<uint8_t> &out,
                                             std::string &error) const {
    error.clear();
    if (!_committed.committed || _scratch.epoch_active ||
        _outbox_count != 0 || _inbox_count != 0) {
        error = "economy_pod_ecp1_save_blocked";
        return false;
    }
    out.clear();
    append_u32(out, RUNTIME_ECONOMY_POD_SECTION_MARKER);
    append_u32(out, 2u); // abi2: business summary scalars after header
    const size_t size_at = out.size();
    append_u32(out, 0u);
    append_u64(out, _committed.session_epoch);
    append_u64(out, _committed.generation);
    append_u64(out, _committed.state_hash);
    append_u64(out, static_cast<uint64_t>(_committed.committed_day));
    append_u64(out, _input.catalog_hash);
    append_u32(out, _operation_gate_mask);
    append_u32(out, _parity_ready_mask);
    append_u32(out, static_cast<uint32_t>(_terminal_receipts.size()));
    append_i64(out, _committed.population_error);
    append_i64(out, _committed.money_error);
    append_i64(out, _committed.goods_error);
    append_i64(out, _summary_population);
    append_i64(out, _summary_funds);
    append_i32(out, _summary_markets);
    append_i32(out, _summary_buildings);
    append_i32(out, _summary_cohorts);
    append_i32(out, _summary_families);
    for (const RuntimeEconomyPodReceipt &receipt : _terminal_receipts) {
        append_u64(out, receipt.request_id);
        append_u64(out, receipt.transaction_id);
        append_u32(out, static_cast<uint32_t>(receipt.opcode));
        append_u32(out, static_cast<uint32_t>(receipt.code));
    }
    const uint32_t payload_size =
        static_cast<uint32_t>(out.size() - size_at - 4u);
    out[size_at] = static_cast<uint8_t>(payload_size & 0xffu);
    out[size_at + 1] = static_cast<uint8_t>((payload_size >> 8) & 0xffu);
    out[size_at + 2] = static_cast<uint8_t>((payload_size >> 16) & 0xffu);
    out[size_at + 3] = static_cast<uint8_t>((payload_size >> 24) & 0xffu);
    append_u64(out, fnv1a(out.data(), out.size()));
    return true;
}

bool RuntimeEconomyPodAuthority::restore_ecp1(const uint8_t *data, size_t size,
                                              std::string &error) {
    error.clear();
    if (data == nullptr || size < 24) {
        error = "economy_pod_ecp1_truncated";
        return false;
    }
    const uint64_t expected = fnv1a(data, size - 8);
    uint64_t actual = 0;
    const uint8_t *tail = data + size - 8;
    if (!read_u64(tail, data + size, actual) || actual != expected) {
        error = "economy_pod_ecp1_checksum";
        return false;
    }
    const uint8_t *p = data;
    const uint8_t *end = data + size - 8;
    uint32_t marker = 0, abi = 0, payload_size = 0;
    if (!read_u32(p, end, marker) || marker != RUNTIME_ECONOMY_POD_SECTION_MARKER ||
        !read_u32(p, end, abi) || (abi != 1u && abi != 2u) ||
        !read_u32(p, end, payload_size)) {
        error = "economy_pod_ecp1_header_invalid";
        return false;
    }
    uint64_t session = 0, generation = 0, state_hash = 0, day = 0, catalog = 0;
    uint32_t gate = 0, parity = 0, receipt_count = 0;
    if (!read_u64(p, end, session) || !read_u64(p, end, generation) ||
        !read_u64(p, end, state_hash) || !read_u64(p, end, day) ||
        !read_u64(p, end, catalog) || !read_u32(p, end, gate) ||
        !read_u32(p, end, parity) || !read_u32(p, end, receipt_count)) {
        error = "economy_pod_ecp1_payload_invalid";
        return false;
    }
    int64_t pop_err = 0, money_err = 0, goods_err = 0;
    int64_t summary_population = 0, summary_funds = 0;
    int32_t summary_markets = 0, summary_buildings = 0;
    int32_t summary_cohorts = 0, summary_families = 0;
    if (abi == 2u) {
        if (!read_i64(p, end, pop_err) || !read_i64(p, end, money_err) ||
            !read_i64(p, end, goods_err) ||
            !read_i64(p, end, summary_population) ||
            !read_i64(p, end, summary_funds) ||
            !read_i32(p, end, summary_markets) ||
            !read_i32(p, end, summary_buildings) ||
            !read_i32(p, end, summary_cohorts) ||
            !read_i32(p, end, summary_families)) {
            error = "economy_pod_ecp1_abi2_truncated";
            return false;
        }
    }
    _terminal_receipts.clear();
    for (uint32_t i = 0; i < receipt_count; ++i) {
        RuntimeEconomyPodReceipt receipt;
        uint32_t opcode = 0, code = 0;
        if (!read_u64(p, end, receipt.request_id) ||
            !read_u64(p, end, receipt.transaction_id) ||
            !read_u32(p, end, opcode) || !read_u32(p, end, code)) {
            error = "economy_pod_ecp1_receipt_truncated";
            return false;
        }
        receipt.opcode = static_cast<int32_t>(opcode);
        receipt.code = static_cast<RuntimeEconomyCommandReceiptCode>(code);
        _terminal_receipts.push_back(receipt);
    }
    _committed = RuntimeEconomyCommittedSnapshot{};
    _committed.session_epoch = session;
    _committed.generation = generation;
    _committed.state_hash = state_hash;
    _committed.committed_day = static_cast<int64_t>(day);
    _committed.committed = true;
    _committed.completed_stage_mask = RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK;
    _committed.population_error = pop_err;
    _committed.money_error = money_err;
    _committed.goods_error = goods_err;
    _operation_gate_mask = gate;
    _parity_ready_mask = parity;
    _generation = generation;
    _input.catalog_hash = catalog;
    _input.session_epoch = session;
    _scratch = RuntimeEconomyWorkerScratch{};
    _summary_population = summary_population;
    _summary_funds = summary_funds;
    _summary_markets = summary_markets;
    _summary_buildings = summary_buildings;
    _summary_cohorts = summary_cohorts;
    _summary_families = summary_families;
    // Preserve abi2 summaries into the snapshot ring for round-trip observers.
    if (abi == 2u) {
        uint32_t ring_index = 0;
        if (_snapshot_ring.try_begin_write(ring_index)) {
            RuntimeEconomySnapshotPayload &payload =
                _snapshot_ring.write_buffer(ring_index);
            payload = RuntimeEconomySnapshotPayload{};
            payload.header = _committed;
            payload.catalog_hash = catalog;
            payload.operation_gate_mask = gate;
            payload.population_error = pop_err;
            payload.money_error = money_err;
            payload.goods_error = goods_err;
            payload.summary_population = summary_population;
            payload.summary_funds = summary_funds;
            payload.summary_markets = summary_markets;
            payload.summary_buildings = summary_buildings;
            payload.summary_cohorts = summary_cohorts;
            payload.summary_families = summary_families;
            _snapshot_ring.publish(ring_index);
        }
    }
    return true;
}

bool RuntimeEconomyPodAuthority::self_test(std::string &error) {
    error.clear();
    if (!economy_graph_kernels_self_test(error)) return false;
    if (!RuntimeEconomySnapshotRing::self_test()) {
        error = "economy_snapshot_ring_self_test_failed";
        return false;
    }

    RuntimeEconomyPodAuthority authority;
    RuntimeEconomyEpochInput input;
    input.sample_day = 3;
    input.session_epoch = 1;
    input.economy_generation = 7;
    input.input_generation = 11;
    input.country_generation = 13;
    input.catalog_hash = 17;
    input.policy_hash = 19;
    input.environment_shape_hash = 23;
    input.cell_count = 4;
    input.market_cycle_days = 5;
    input.production_cycle_days = 10;
    input.investment_cycle_days = 20;
    input.valid = true;
    if (!authority.plan_epoch(input, error)) return false;
    for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
        authority.set_stage_reference(
            static_cast<RuntimeEconomyGraphStage>(i), 3, 7,
            0, // will not match unless ops attached; Phase2 hash-boundary ok
            4);
        if (!authority.advance_stage(error)) return false;
    }
    if (authority.completed_stage_mask() != RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK) {
        error = "economy_pod_stage_contract_failed";
        return false;
    }
    RuntimeEconomyPodCommand command;
    command.request_id = 99;
    command.opcode = 1;
    command.session_epoch = 1;
    if (!authority.queue_command(command, error)) return false;
    if (!authority.commit_epoch(error)) return false;
    RuntimeEconomyPodReceipt committed;
    if (!authority.poll_receipt(committed) ||
        committed.code != RuntimeEconomyCommandReceiptCode::Committed ||
        committed.request_id != 99) {
        error = "economy_pod_commit_receipt_missing";
        return false;
    }
    // Duplicate request_id must return the prior terminal.
    if (!authority.queue_command(command, error)) return false;
    RuntimeEconomyPodReceipt duplicate;
    if (!authority.poll_receipt(duplicate) ||
        duplicate.code != RuntimeEconomyCommandReceiptCode::Committed ||
        duplicate.request_id != 99) {
        error = "economy_pod_duplicate_request_id_failed";
        return false;
    }

    // Opcode admission coverage (fresh authority after commit).
    RuntimeEconomyPodAuthority admit;
    RuntimeEconomyEpochInput admit_input = input;
    admit_input.economy_generation = 1;
    if (!admit.plan_epoch(admit_input, error)) return false;
    // Force a non-zero generation for mismatch checks without full commit.
    for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
        admit.set_stage_reference(static_cast<RuntimeEconomyGraphStage>(i), 3, 1,
                                  0, 4);
        if (!admit.advance_stage(error)) return false;
    }
    if (!admit.commit_epoch(error)) return false;
    const uint64_t live_generation = admit.epoch_input().economy_generation;
    (void)live_generation;

    RuntimeEconomyPodCommand bad_opcode;
    bad_opcode.request_id = 1000;
    bad_opcode.opcode = 0;
    bad_opcode.session_epoch = 1;
    if (!admit.queue_command(bad_opcode, error)) return false;
    RuntimeEconomyPodReceipt rejected;
    if (!admit.poll_receipt(rejected) ||
        rejected.code !=
            RuntimeEconomyCommandReceiptCode::RejectedAtAdmission) {
        error = "economy_pod_opcode_zero_should_reject";
        return false;
    }

    RuntimeEconomyPodCommand session_mismatch;
    session_mismatch.request_id = 1001;
    session_mismatch.opcode = 1;
    session_mismatch.session_epoch = 999;
    if (!admit.queue_command(session_mismatch, error)) return false;
    if (!admit.poll_receipt(rejected) ||
        rejected.code !=
            RuntimeEconomyCommandReceiptCode::RejectedAtAdmission) {
        error = "economy_pod_session_mismatch_should_reject";
        return false;
    }

    RuntimeEconomyPodCommand gen_mismatch;
    gen_mismatch.request_id = 1002;
    gen_mismatch.opcode = 1;
    gen_mismatch.session_epoch = 1;
    gen_mismatch.economy_generation = 999999;
    if (!admit.queue_command(gen_mismatch, error)) return false;
    if (!admit.poll_receipt(rejected) ||
        rejected.code !=
            RuntimeEconomyCommandReceiptCode::RejectedAtAdmission) {
        error = "economy_pod_generation_mismatch_should_reject";
        return false;
    }

    for (int32_t opcode = 1; opcode <= 23; ++opcode) {
        RuntimeEconomyPodCommand batch;
        batch.request_id = 2000 + static_cast<uint64_t>(opcode);
        batch.opcode = opcode;
        batch.session_epoch = 1;
        batch.economy_generation = 0; // wildcard
        if (opcode == 20) batch.payload0 = 1; // canal token present
        if (!admit.queue_command(batch, error)) return false;
    }
    for (int32_t opcode = 1; opcode <= 23; ++opcode) {
        RuntimeEconomyPodReceipt accepted;
        if (!admit.poll_receipt(accepted) ||
            accepted.code != RuntimeEconomyCommandReceiptCode::Accepted) {
            error = "economy_pod_opcode_batch_admit_failed";
            return false;
        }
    }

    // BUILD_CANAL without token rejects at execution on commit.
    RuntimeEconomyPodAuthority canal;
    if (!canal.plan_epoch(input, error)) return false;
    for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
        canal.set_stage_reference(static_cast<RuntimeEconomyGraphStage>(i), 3, 7,
                                  0, 4);
        if (!canal.advance_stage(error)) return false;
    }
    RuntimeEconomyPodCommand canal_cmd;
    canal_cmd.request_id = 3000;
    canal_cmd.opcode = 20;
    canal_cmd.session_epoch = 1;
    canal_cmd.payload0 = 0;
    if (!canal.queue_command(canal_cmd, error)) return false;
    if (!canal.commit_epoch(error)) return false;
    RuntimeEconomyPodReceipt canal_receipt;
    if (!canal.poll_receipt(canal_receipt) ||
        canal_receipt.code !=
            RuntimeEconomyCommandReceiptCode::RejectedAtExecution) {
        error = "economy_pod_build_canal_token_reject_failed";
        return false;
    }

    // Executor apply failure → RejectedAtExecution (ACTIVE Host always attaches).
    class FailingEconomyPodExecutor final : public EconomyPodCommandExecutor {
    public:
        bool apply(const RuntimeEconomyPodCommand &,
                   std::string &apply_error) override {
            apply_error = "economy_pod_test_apply_failed";
            return false;
        }
    };
    RuntimeEconomyPodAuthority apply_fail;
    if (!apply_fail.plan_epoch(input, error)) return false;
    for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
        apply_fail.set_stage_reference(
            static_cast<RuntimeEconomyGraphStage>(i), 3, 7, 0, 4);
        if (!apply_fail.advance_stage(error)) return false;
    }
    FailingEconomyPodExecutor failing;
    apply_fail.attach_command_executor(&failing);
    RuntimeEconomyPodCommand fail_cmd;
    fail_cmd.request_id = 4000;
    fail_cmd.opcode = 1;
    fail_cmd.session_epoch = 1;
    if (!apply_fail.queue_command(fail_cmd, error)) return false;
    if (!apply_fail.commit_epoch(error)) return false;
    RuntimeEconomyPodReceipt fail_receipt;
    if (!apply_fail.poll_receipt(fail_receipt) ||
        fail_receipt.code !=
            RuntimeEconomyCommandReceiptCode::RejectedAtExecution) {
        error = "economy_pod_apply_failure_reject_failed";
        return false;
    }

    std::vector<uint8_t> encoded;
    if (!authority.encode_ecp1(encoded, error) || encoded.size() < 24) {
        if (error.empty()) error = "economy_pod_ecp1_encode_failed";
        return false;
    }
    RuntimeEconomyPodAuthority restored;
    if (!restored.restore_ecp1(encoded.data(), encoded.size(), error))
        return false;
    return true;
}

} // namespace pk

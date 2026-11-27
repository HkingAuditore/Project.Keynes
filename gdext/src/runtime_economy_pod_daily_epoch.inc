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
        const uint32_t resume = _stage_ops->resume_stage_index();
        if (resume >= RUNTIME_ECONOMY_GRAPH_STAGE_COUNT) {
            error = "economy_pod_resume_stage_invalid";
            return false;
        }
        _scratch.stage_index = resume;
        _stage_cursor.stage_index = resume;
        // Earlier stages are already complete in the surviving formula owner.
        // Their old timings/hashes are unavailable; never replay their mutations.
        _completed_stage_mask = (1u << resume) - 1u;
        _replay.completed_stage_mask = _completed_stage_mask;
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
    _replay.stage_ms[index] += ms;
    _replay.completed_stage_mask |= runtime_economy_graph_stage_bit(stage);
    _replay.stage_cursor = static_cast<uint32_t>(
        std::max<uint64_t>(_replay.stage_cursor, work));
    _completed_stage_mask = _replay.completed_stage_mask;
    _replay.next_hash = stage_hash;

    if (_reference_present[index] != 0 &&
        (_input.stage_hashes_enabled || stage == RuntimeEconomyGraphStage::AGGREGATE_PUBLISH)) {
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
            const size_t index = static_cast<size_t>(stage);
            if (index < RuntimeEconomyPodReplayReport::STAGE_COUNT) {
                _replay.stage_ms[index] += elapsed_ms(begin);
            }
            // Peer parks must not poison the epoch. commit_epoch treats any
            // replay fatal as economy_pod_fatal even if the slice later retries.
            const bool peer_park =
                error == "country_research_peer_results" ||
                error == "fiscal_settlement_peer_pending" ||
                error == "fiscal_reserve_peer_results" ||
                error == "fiscal_peer_results" ||
                runtime_country_asset_pending_reason(error);
            if (result.fatal && !peer_park) {
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

    // ACTIVE 无命令时不构造即将被 Host 再次刷新的投影；有命令仍保留
    // 执行前投影及执行后最终导出，不能让命令读到上一代 domain 数据。
    if (!_commands.empty() && !_input.stage_hashes_enabled &&
        _stage_ops != nullptr && _view.runtime_hook != nullptr) {
        auto *runtime = static_cast<NativeEconomyRuntime *>(_view.runtime_hook);
        if (runtime->formula_owned_bound())
            runtime->flush_formula_owned_domain_mirrors();
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

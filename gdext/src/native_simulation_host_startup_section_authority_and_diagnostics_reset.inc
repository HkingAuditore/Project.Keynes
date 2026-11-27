    _last_command_admitted_us.store(0, std::memory_order_release);
    _economy_authority_switch_command_latency_us.store(0,
                                                       std::memory_order_release);
    _economy_authority_switch_latency_us.store(0,
                                                std::memory_order_release);
    _economy_authority_switch_latency_p95_us.store(0,
                                                    std::memory_order_release);
    _economy_authority_switch_latency_max_us.store(0,
                                                    std::memory_order_release);
    _economy_authority_switch_command_latency_p95_us.store(
        0, std::memory_order_release);
    _economy_authority_switch_command_latency_max_us.store(
        0, std::memory_order_release);
    _economy_authority_switch_latency_sample_count.store(
        0, std::memory_order_release);
    _economy_authority_switch_latency_sample_write.store(
        0, std::memory_order_release);
    for (auto &sample : _economy_authority_switch_latency_samples)
        sample.store(0, std::memory_order_release);
    for (auto &sample : _economy_authority_switch_command_latency_samples)
        sample.store(0, std::memory_order_release);
    _economy_authority_switch_audit_sequence.store(0,
        std::memory_order_release);
    _economy_authority_switch_audit_hash.store(0, std::memory_order_release);
    _ui_input_to_feedback_ms.store(0.0, std::memory_order_release);
    _visual_apply_ms.store(0.0, std::memory_order_release);
    _gpu_upload_ms.store(0.0, std::memory_order_release);
    _completed_days.store(0, std::memory_order_release);
    _last_day_stage_count.store(0, std::memory_order_release);
    _last_day_completed_stages.store(0, std::memory_order_release);
    _last_day_work_units.store(0, std::memory_order_release);
    _pod_completed_domain_mask.store(0, std::memory_order_release);
    _pod_completed_stage_count.store(0, std::memory_order_release);
    _pod_work_units.store(0, std::memory_order_release);
    _pod_intent_count.store(0, std::memory_order_release);
    _pod_fallback_count.store(0, std::memory_order_release);
    _economy_pod_ready.store(false, std::memory_order_release);
    _economy_pod_committed.store(false, std::memory_order_release);
    _economy_pod_authority_ready.store(false, std::memory_order_release);
    _economy_pod_committed_day.store(-1, std::memory_order_release);
    _economy_pod_epoch_sample_day.store(-1, std::memory_order_release);
    _economy_pod_generation.store(0, std::memory_order_release);
    _economy_pod_state_hash.store(0, std::memory_order_release);
    _economy_pod_input_generation.store(0, std::memory_order_release);
    _economy_pod_country_generation.store(0, std::memory_order_release);
    _economy_pod_completed_stage_mask.store(0, std::memory_order_release);
    _economy_pod_pending_outbox.store(0, std::memory_order_release);
    _economy_pod_pending_inbox.store(0, std::memory_order_release);
    _economy_pod_operation_gate_mask.store(0, std::memory_order_release);
    _economy_pod_parity_ready_mask.store(0, std::memory_order_release);
    _economy_sync_writes_forbidden.store(false, std::memory_order_release);
    _economy_input_requested_day.store(-1, std::memory_order_release);

    _economy_input_signal.store(0, std::memory_order_release);
    _economy_shadow_stage_invocations.store(0, std::memory_order_release);
    _economy_shadow_stage_cache_hits.store(0, std::memory_order_release);
    _economy_pod_command_recapture_count.store(0, std::memory_order_release);
    _economy_pod_command_verify_count.store(0, std::memory_order_release);
    _economy_shadow_cache_valid = false;
    _economy_shadow_cache_day = -1;
    _economy_shadow_cache_input_generation = 0;
    _economy_shadow_cache_country_generation = 0;
    _economy_shadow_cache_catalog_hash = 0;
    _economy_replay_completed_stage_mask.store(0, std::memory_order_release);
    _economy_replay_stage_cursor.store(0, std::memory_order_release);
    _economy_replay_input_hash.store(0, std::memory_order_release);
    _economy_replay_base_hash.store(0, std::memory_order_release);
    _economy_replay_next_hash.store(0, std::memory_order_release);
    for (auto &value : _economy_replay_stage_hash)
        value.store(0, std::memory_order_release);
    for (auto &value : _economy_replay_stage_work)
        value.store(0, std::memory_order_release);
    for (auto &value : _economy_replay_stage_ms)
        value.store(0.0, std::memory_order_release);
    _economy_replay_input_captured.store(false, std::memory_order_release);
    _economy_replay_committed.store(false, std::memory_order_release);
    _economy_replay_parity_ready.store(false, std::memory_order_release);
    for (auto &value : _economy_replay_fallback_reason)
        value.store('\0', std::memory_order_release);
    _economy_reference_day.store(-1, std::memory_order_release);
    _economy_reference_generation.store(0, std::memory_order_release);
    _economy_reference_hash.store(0, std::memory_order_release);
    for (auto &value : _economy_stage_reference_hash)
        value.store(0, std::memory_order_release);
    for (auto &value : _economy_stage_reference_work)
        value.store(0, std::memory_order_release);
    for (auto &value : _economy_stage_reference_present)
        value.store(0, std::memory_order_release);
    _economy_pod_authority.reset();
    _domain_authority_planned_mask.store(0, std::memory_order_release);
    _domain_authority_committed_mask.store(0, std::memory_order_release);
    _domain_authority_ack_count.store(0, std::memory_order_release);
    _domain_authority_input_hash.store(0, std::memory_order_release);
    _domain_authority_state_hash.store(0, std::memory_order_release);
    _domain_authority_plan_ms.store(0.0, std::memory_order_release);
    _domain_authority_replay_ms.store(0.0, std::memory_order_release);
    for (auto &character : _domain_authority_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    _domain_stage_fallback_count.store(0, std::memory_order_release);
    for (auto &character : _domain_stage_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    _country_pod_ready.store(false, std::memory_order_release);
    for (auto &character : _country_pod_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    _country_parity_compared.store(0, std::memory_order_release);
    _country_parity_matched.store(0, std::memory_order_release);
    _country_parity_compared_count.store(0, std::memory_order_release);
    _country_parity_matched_count.store(0, std::memory_order_release);
    _country_parity_first_mismatch_day.store(-1, std::memory_order_release);
    _country_parity_reference_hash.store(0, std::memory_order_release);
    _country_parity_worker_hash.store(0, std::memory_order_release);
    _country_parity_index.store(-1, std::memory_order_release);
    for (auto &character : _country_parity_status)
        character.store('\0', std::memory_order_relaxed);
    for (auto &character : _country_parity_field)
        character.store('\0', std::memory_order_relaxed);
    _climate_pod_ready.store(false, std::memory_order_release);
    _climate_pod_plan_ms.store(0.0, std::memory_order_release);
    _climate_pod_replay_ms.store(0.0, std::memory_order_release);
    _climate_pod_work_units.store(0, std::memory_order_release);
    _climate_pod_changed_cells.store(0, std::memory_order_release);
    for (size_t i = 0; i < _climate_stage_ms.size(); ++i) {
        _climate_stage_ms[i].store(0.0, std::memory_order_relaxed);
        _climate_stage_work[i].store(0, std::memory_order_relaxed);
    }
    _climate_pod_state_hash.store(0, std::memory_order_release);
    _climate_pod_reference_hash.store(0, std::memory_order_release);
    _climate_pod_parity_compared.store(false, std::memory_order_release);
    _climate_pod_parity_matched.store(false, std::memory_order_release);
    _climate_pod_parity_mismatch_count.store(0, std::memory_order_release);
    for (auto &character : _climate_pod_parity_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    _climate_parity_day.store(-1, std::memory_order_release);
    _climate_parity_stage.store(0, std::memory_order_release);
    _climate_parity_cell.store(0, std::memory_order_release);
    _climate_parity_input_generation.store(0, std::memory_order_release);
    _climate_parity_base_generation.store(0, std::memory_order_release);
    _climate_parity_trace_hash.store(0, std::memory_order_release);
    for (auto &character : _climate_parity_field) character.store('\0', std::memory_order_relaxed);
    for (auto &character : _climate_parity_reference_bits) character.store('\0', std::memory_order_relaxed);
    for (auto &character : _climate_parity_worker_bits) character.store('\0', std::memory_order_relaxed);
    for (auto &character : _climate_pod_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    _modifier_pod_ready.store(false, std::memory_order_release);
    _modifier_pod_plan_ms.store(0.0, std::memory_order_release);
    _modifier_pod_replay_ms.store(0.0, std::memory_order_release);
    _modifier_pod_work_units.store(0, std::memory_order_release);
    _modifier_pod_state_hash.store(0, std::memory_order_release);
    _modifier_pod_snapshot_generation.store(0, std::memory_order_release);
    _modifier_pod_ack_count.store(0, std::memory_order_release);
    for (auto &character : _modifier_pod_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    _time_debt_days.store(std::clamp(start_time_debt, 0.0, 100.0),
                          std::memory_order_release);
    const auto existing_environment = restore_pending
        ? std::atomic_load_explicit(&_environment_snapshot, std::memory_order_acquire)
        : environment_snapshot();
    if (existing_environment != nullptr) {
        _environment_generation.store(existing_environment->generation, std::memory_order_release);
        _environment_day.store(existing_environment->day, std::memory_order_release);
        _environment_cell_count.store(existing_environment->cell_count,
                                      std::memory_order_release);
        _environment_topology_validated.store(existing_environment->topology_validated,
                                              std::memory_order_release);
    } else {
        _environment_generation.store(0, std::memory_order_release);
        _environment_day.store(restored_environment_day, std::memory_order_release);
        _environment_cell_count.store(0, std::memory_order_release);
        _environment_topology_validated.store(false, std::memory_order_release);
    }
    if (restored_environment_generation >
            _environment_generation.load(std::memory_order_acquire)) {
        _environment_generation.store(restored_environment_generation,
                                      std::memory_order_release);
        _environment_day.store(restored_environment_day,
                               std::memory_order_release);
    }
    _command_enqueue_pos.store(0, std::memory_order_relaxed);
    _command_dequeue_pos.store(0, std::memory_order_relaxed);
    _receipt_write.store(0, std::memory_order_relaxed);
    _receipt_read.store(0, std::memory_order_relaxed);
    for (size_t i = 0; i < _producer_sequences.size(); ++i) {
        if (restore_pending) _producer_sequences[i].store(
            _pending_restore_bundle.producer_sequences[i], std::memory_order_relaxed);
    }
    if (restore_pending) _fallback_producer_sequence.store(
        _pending_restore_bundle.fallback_producer_sequence, std::memory_order_relaxed);
    _save_requested.store(false, std::memory_order_release);
    _save_request_id.store(0, std::memory_order_release);
    _save_consumed_request_id.store(0, std::memory_order_release);
    _save_failed_request_id.store(0, std::memory_order_release);
    std::atomic_store_explicit(&_save_bundle,
        std::shared_ptr<const RuntimeSaveBundle>(), std::memory_order_release);
    // WorldRuntimeHost captures the initial immutable input immediately
    // before starting the worker. Preserve that frame so the OFF reference
    // can release it after the synchronous day boundary. A trace belonging to
    // another start/day is discarded explicitly.
    int64_t trace_front_day = -1;
    // A fresh world captures the first worker input for the next simulation
    // day before the worker starts: the Host clock is at day N while the
    // first comparable Climate frame is day N+1. Restarts and restores already
    // have an unfinished frame for their exact committed day, so keep their
    // strict start-day match.
    const int64_t expected_trace_day =
        (!restore_pending && !resuming_previous_lifetime)
            ? start_day + 1 : start_day;
    if (_climate_trace.front_day(trace_front_day) &&
        trace_front_day != expected_trace_day) {
        _climate_trace.reset();
    }
    _climate_trace_consumed.store(0, std::memory_order_release);
    _climate_trace_missing.store(0, std::memory_order_release);
    _climate_trace_latest_hash.store(0, std::memory_order_release);
    _climate_trace_signal.store(0, std::memory_order_release);
    clear_climate_parity_divergence();
    reset_climate_parity_fields();
    _state_hash.store(start_state_hash, std::memory_order_release);
    auto initial = std::make_shared<RuntimeCommit>();
    RuntimeCommitHeader &initial_commit = initial->header;
    initial_commit.generation = start_generation;
    initial_commit.from_day = start_day;
    initial_commit.committed_day = start_day;
    initial_commit.state_hash = start_state_hash;
    if (auto vision = latest_vision()) {
        auto tail = std::make_shared<RuntimeDayTail>();
        tail->vision = std::move(vision);
        initial->day_tail = std::move(tail);
    }
    std::atomic_store_explicit(&_latest_commit,
        std::shared_ptr<const RuntimeCommit>(std::move(initial)),
        std::memory_order_release);
    // Restore input is staged outside the stopped timeline's queue. Its queued
    // future frames must not shadow the replacement snapshot during reseeding.
    const auto bootstrap_environment = restore_pending
        ? std::atomic_load_explicit(&_environment_snapshot, std::memory_order_acquire)
        : environment_snapshot();
    const auto bootstrap_country = std::atomic_load_explicit(
        &_country_snapshot, std::memory_order_acquire);
    _pod_pipeline.reset(
        bootstrap_environment != nullptr ? bootstrap_environment->cell_count : 0u,
        bootstrap_country != nullptr ? bootstrap_country->country_count : 0u);
    _authoritative_domains.reset(
        bootstrap_environment != nullptr ? bootstrap_environment->cell_count : 0u,
        bootstrap_country != nullptr ? bootstrap_country->country_count : 0u);
    _domain_authority_runner.reset(
        bootstrap_environment != nullptr ? bootstrap_environment->cell_count : 0u,
        bootstrap_country != nullptr ? bootstrap_country->country_count : 0u);
    _modifier_snapshots.reset();
    _effect_snapshots.reset();
    _ideology_snapshots.reset();
    _opinion_view_version = {}; _annual_ideology_view_version = {}; _country_ai_economy_view_version = {}; _annual_country_view_version = {};
    _events_authority.reset();
    _events_snapshots.reset();
    _events_last_processed_day = -1;
    _economy_fact_event_sequence = restore_pending ? _pending_restore_bundle.economy_fact_event_sequence : 0;
    _trigger_forwarded_event_id = restore_pending ? _pending_restore_bundle.trigger_forwarded_event_id : 0;
    _trigger_forward_sequence = restore_pending ? _pending_restore_bundle.trigger_forward_sequence : 0;
    _events_pod_ready.store(false, std::memory_order_release);
    _events_pod_plan_ms.store(0.0, std::memory_order_release);
    _events_pod_replay_ms.store(0.0, std::memory_order_release);
    _events_pod_state_hash.store(0, std::memory_order_release);
    _events_pod_snapshot_generation.store(0, std::memory_order_release);
    _events_pod_event_count.store(0, std::memory_order_release);
    _events_pod_ack_count.store(0, std::memory_order_release);
    _events_pod_drop_count.store(0, std::memory_order_release);
    _events_pod_rejected_count.store(0, std::memory_order_release);
    _events_failed_day.store(-1, std::memory_order_release);
    for (auto &character : _events_pod_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);

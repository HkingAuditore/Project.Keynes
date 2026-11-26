static Dictionary runtime_report_to_dictionary(const RuntimeThreadReport &report,
                                               const NativeSimulationHost *host) {
    Dictionary out;
    out["domain_abi_version"] = static_cast<int>(report.domain_abi_version);
    out["pod_domain_abi_version"] = static_cast<int>(report.pod_domain_abi_version);
    // Keep the explicit protocol name as a stable diagnostic alias.
    out["runtime_domain_abi_version"] = static_cast<int>(report.domain_abi_version);
    out["state"] = runtime_state_name(report.state);
    out["state_id"] = static_cast<int>(report.state);
    out["requested_simulation_thread_mode"] = runtime_mode_name(report.mode);
    out["simulation_thread_mode"] = runtime_mode_name(report.mode);
    // native_daily_inline：日屏障由调用线程执行，本 host 没有 worker 线程。
    out["native_daily_inline"] = report.inline_daily;
    out["graph_coverage_complete"] = report.graph_coverage_complete;
    out["authority_ready"] = report.authority_ready;
    out["required_domain_mask"] = static_cast<int64_t>(report.required_domain_mask);
    out["implemented_domain_mask"] = static_cast<int64_t>(report.implemented_domain_mask);
    out["missing_domain_mask"] = static_cast<int64_t>(report.missing_domain_mask);
    out["active_evidence_mask"] = static_cast<int64_t>(report.active_evidence_mask);
    // The masks a caller must gate on, next to the one it must not gate on alone.
    // `authority_window_blocker` says WHY a requested domain is still blocked.
    if (host != nullptr) append_main_thread_suppression(*host, report, out);
    out["completion_gate_missing_domain_mask"] = static_cast<int64_t>(report.completion_gate_missing_domain_mask);
    out["active_gate_blocked"] = report.active_gate_blocked;
    out["graph_coverage_state"] = String(report.graph_coverage_state);
    out["coverage_blocker"] = String(report.coverage_blocker);
    out["simulation_worker_blocker"] = String(report.coverage_blocker);
    out["interactive"] = report.interactive;
    out["paused"] = report.paused;
    out["speed_days_per_second"] = report.speed_days_per_second;
    out["committed_day"] = report.committed_day;
    out["generation"] = static_cast<int64_t>(report.generation);
    out["state_hash"] = static_cast<int64_t>(report.state_hash);
    out["last_commit_produced_at_us"] = static_cast<int64_t>(report.last_commit_produced_at_us);
    out["ui_input_to_feedback_ms"] = report.ui_input_to_feedback_ms;
    out["visual_apply_ms"] = report.visual_apply_ms;
    out["gpu_upload_ms"] = report.gpu_upload_ms;
    append_worker_timing(report.worker_time_us, out);
    out["main_wait_on_sim_us"] = static_cast<int64_t>(report.main_wait_on_sim_us);
    out["environment_generation"] = static_cast<int64_t>(report.environment_generation);
    out["environment_day"] = report.environment_day;
    out["environment_cell_count"] = static_cast<int>(report.environment_cell_count);
    out["environment_topology_validated"] = report.environment_topology_validated;
    out["invalid_environment_rejected"] = static_cast<int64_t>(report.invalid_environment_rejected);
    out["stale_environment_rejected"] = static_cast<int64_t>(report.stale_environment_rejected);
    out["input_capture_count"] = static_cast<int64_t>(report.input_capture_count);
    out["input_capture_reused"] = static_cast<int64_t>(report.input_capture_reused);
    out["input_capture_generation"] = static_cast<int64_t>(report.input_capture_generation);
    out["input_capture_day"] = report.input_capture_day;
    out["input_capture_hash"] = static_cast<int64_t>(report.input_capture_hash);
    out["gameplay_effect_generation"] = static_cast<int64_t>(report.gameplay_effect_generation);
    out["gameplay_effect_pending"] = static_cast<int>(report.gameplay_effect_pending);
    out["gameplay_effect_terminal"] = static_cast<int>(report.gameplay_effect_terminal);
    out["gameplay_effect_state_hash"] = static_cast<int64_t>(report.gameplay_effect_state_hash);
    out["command_queue_capacity_exceeded"] = static_cast<int64_t>(report.command_queue_capacity_exceeded);
    out["receipt_queue_capacity_exceeded"] = static_cast<int64_t>(report.receipt_queue_capacity_exceeded);
    out["worker_fault_count"] = static_cast<int64_t>(report.worker_fault_count);
    out["completed_days"] = static_cast<int64_t>(report.completed_days);
    out["day_stage_count"] = static_cast<int>(report.day_stage_count);
    out["day_completed_stage_count"] = static_cast<int>(report.day_completed_stage_count);
    out["day_work_units"] = static_cast<int64_t>(report.day_work_units);
    out["pod_completed_domain_mask"] = static_cast<int64_t>(report.pod_completed_domain_mask);
    out["pod_completed_stage_count"] = static_cast<int>(report.pod_completed_stage_count);
    out["pod_work_units"] = static_cast<int64_t>(report.pod_work_units);
    out["pod_intent_count"] = static_cast<int>(report.pod_intent_count);
    out["pod_fallback_count"] = static_cast<int>(report.pod_fallback_count);
    out["economy_pod_ready"] = report.economy_pod_ready;
    out["economy_pod_committed"] = report.economy_pod_committed;
    out["economy_pod_authority_ready"] = report.economy_pod_authority_ready;
    out["economy_pod_committed_day"] = report.economy_pod_committed_day;
    out["economy_pod_epoch_sample_day"] = report.economy_pod_epoch_sample_day;
    out["economy_pod_generation"] = static_cast<int64_t>(report.economy_pod_generation);
    out["economy_pod_state_hash"] = static_cast<int64_t>(report.economy_pod_state_hash);
    out["economy_pod_input_generation"] = static_cast<int64_t>(report.economy_pod_input_generation);
    out["economy_pod_country_generation"] = static_cast<int64_t>(report.economy_pod_country_generation);
    out["economy_pod_completed_stage_mask"] = static_cast<int64_t>(report.economy_pod_completed_stage_mask);
    out["economy_pod_pending_outbox"] = static_cast<int>(report.economy_pod_pending_outbox);
    out["economy_pod_pending_inbox"] = static_cast<int>(report.economy_pod_pending_inbox);
    out["economy_pod_operation_gate_mask"] = static_cast<int>(report.economy_pod_operation_gate_mask);
    out["economy_pod_parity_ready_mask"] = static_cast<int>(report.economy_pod_parity_ready_mask);
    out["economy_pod_mirror_feature_mask"] =
        static_cast<int>(report.economy_pod_mirror_feature_mask);
    out["economy_pod_committed_ledger_abi"] =
        static_cast<int>(report.economy_pod_committed_ledger_abi);
    out["economy_pod_active_ready"] = report.economy_pod_active_ready;
    out["economy_authority_switch_count"] = report.economy_authority_switch_count;
    out["economy_authority_switch_before_hash"] = report.economy_authority_switch_before_hash;
    out["economy_authority_switch_after_hash"] = report.economy_authority_switch_after_hash;
    out["economy_authority_switch_latency_us"] = report.economy_authority_switch_latency_us;
    out["economy_authority_switch_latency_p95_us"] =
        report.economy_authority_switch_latency_p95_us;
    out["economy_authority_switch_latency_max_us"] =
        report.economy_authority_switch_latency_max_us;
    out["economy_authority_switch_command_latency_us"] =
        report.economy_authority_switch_command_latency_us;
    out["economy_authority_switch_command_latency_p95_us"] =
        report.economy_authority_switch_command_latency_p95_us;
    out["economy_authority_switch_command_latency_max_us"] =
        report.economy_authority_switch_command_latency_max_us;
    out["economy_authority_switch_latency_sample_count"] =
        report.economy_authority_switch_latency_sample_count;
    out["economy_authority_switch_rejected"] = report.economy_authority_switch_rejected;
    out["economy_authority_switch_audit_sequence"] =
        report.economy_authority_switch_audit_sequence;
    out["economy_authority_switch_audit_hash"] = static_cast<int64_t>(
        report.economy_authority_switch_audit_hash);
    out["economy_authority_switch_before_generation"] = static_cast<int64_t>(report.economy_authority_switch_before_generation);
    out["economy_authority_switch_after_generation"] = static_cast<int64_t>(report.economy_authority_switch_after_generation);
    out["economy_authority_fault_paused"] = report.economy_authority_fault_paused;
    out["economy_authority_last_committed_generation"] = static_cast<int64_t>(report.economy_authority_last_committed_generation);
    out["economy_authority_last_committed_hash"] = static_cast<int64_t>(report.economy_authority_last_committed_hash);
    out["economy_inflight_mutations"] = static_cast<int>(report.economy_inflight_mutations);
    out["worker_day_inflight"] = static_cast<int>(report.worker_day_inflight);
    out["economy_pending_command_count"] = static_cast<int>(report.economy_pending_command_count);
    out["economy_authority_switch_reason"] = String(report.economy_authority_switch_reason);
    out["economy_authority_switch_blocker"] = String(report.economy_authority_switch_blocker);
    out["economy_authority_switch_audit_before"] = String(report.economy_authority_switch_audit_before);
    out["economy_authority_switch_audit_after"] = String(report.economy_authority_switch_audit_after);
    out["economy_execution_mode"] = static_cast<int>(report.economy_execution_mode);
    out["economy_execution_mode_name"] = String(
        pk::economy_execution_mode_name(
            static_cast<pk::EconomyExecutionMode>(report.economy_execution_mode)));
    out["economy_shadow_probe_enabled"] = report.economy_shadow_probe_enabled;
    out["economy_shadow_stage_invocations"] =
        static_cast<int64_t>(report.economy_shadow_stage_invocations);
    out["economy_shadow_stage_cache_hits"] =
        static_cast<int64_t>(report.economy_shadow_stage_cache_hits);
    out["economy_stage_ops_mutate"] = report.economy_stage_ops_mutate;
    out["economy_auto_pod_active"] = report.economy_auto_pod_active;
    out["economy_pod_command_recapture_count"] =
        static_cast<int64_t>(report.economy_pod_command_recapture_count);
    out["economy_pod_command_verify_count"] =
        static_cast<int64_t>(report.economy_pod_command_verify_count);
    out["economy_formula_backing"] = String(report.economy_formula_backing);
    out["economy_production_writer"] = String(report.economy_production_writer);
    out["economy_production_writer_requested"] =
        String(report.economy_production_writer_requested);
    out["economy_production_writer_effective"] =
        String(report.economy_production_writer_effective);
    out["economy_stage_ops_readiness_mask"] =
        static_cast<int64_t>(report.economy_stage_ops_readiness_mask);
    out["economy_stage_ops_prelude_ready"] =
        report.economy_stage_ops_prelude_ready;
    out["economy_stage_ops_soak_experiment"] =
        report.economy_stage_ops_soak_experiment;
    out["economy_stage_ops_soak_parity_ok"] =
        report.economy_stage_ops_soak_parity_ok;
    out["economy_replay_completed_stage_mask"] = static_cast<int64_t>(report.economy_replay_completed_stage_mask);
    out["economy_replay_stage_cursor"] = static_cast<int>(report.economy_replay_stage_cursor);
    out["economy_replay_input_hash"] = static_cast<int64_t>(report.economy_replay_input_hash);
    out["economy_replay_base_hash"] = static_cast<int64_t>(report.economy_replay_base_hash);
    out["economy_replay_next_hash"] = static_cast<int64_t>(report.economy_replay_next_hash);
    out["economy_replay_input_captured"] = report.economy_replay_input_captured;
    out["economy_replay_committed"] = report.economy_replay_committed;
    out["economy_replay_parity_ready"] = report.economy_replay_parity_ready;
    out["economy_replay_fallback_reason"] = String(report.economy_replay_fallback_reason);
    PackedInt64Array replay_hashes;
    PackedInt64Array replay_work;
    PackedFloat64Array replay_ms;
    replay_hashes.resize(static_cast<int>(pk::RUNTIME_ECONOMY_GRAPH_STAGE_COUNT));
    replay_work.resize(static_cast<int>(pk::RUNTIME_ECONOMY_GRAPH_STAGE_COUNT));
    replay_ms.resize(static_cast<int>(pk::RUNTIME_ECONOMY_GRAPH_STAGE_COUNT));
    for (int i = 0; i < static_cast<int>(pk::RUNTIME_ECONOMY_GRAPH_STAGE_COUNT); ++i) {
        replay_hashes.set(i, static_cast<int64_t>(report.economy_replay_stage_hash[i]));
        replay_work.set(i, static_cast<int64_t>(report.economy_replay_stage_work[i]));
        replay_ms.set(i, report.economy_replay_stage_ms[i]);
    }
    out["economy_replay_stage_hash"] = replay_hashes;
    out["economy_replay_stage_work"] = replay_work;
    out["economy_replay_stage_ms"] = replay_ms;
    out["domain_authority_planned_mask"] = static_cast<int64_t>(
        report.domain_authority_planned_mask);
    out["domain_authority_committed_mask"] = static_cast<int64_t>(
        report.domain_authority_committed_mask);
    out["domain_authority_ack_count"] = static_cast<int>(
        report.domain_authority_ack_count);
    out["domain_authority_input_hash"] = static_cast<int64_t>(
        report.domain_authority_input_hash);
    out["domain_authority_state_hash"] = static_cast<int64_t>(
        report.domain_authority_state_hash);
    out["domain_authority_plan_ms"] = report.domain_authority_plan_ms;
    out["domain_authority_replay_ms"] = report.domain_authority_replay_ms;
    out["domain_authority_fallback_reason"] = String(
        report.domain_authority_fallback_reason);
    out["domain_stage_fallback_count"] = static_cast<int>(
        report.domain_stage_fallback_count);
    out["domain_stage_fallback_reason"] = String(
        report.domain_stage_fallback_reason);
    out["climate_pod_ready"] = report.climate_pod_ready;
    out["climate_pod_plan_ms"] = report.climate_pod_plan_ms;
    out["climate_pod_replay_ms"] = report.climate_pod_replay_ms;
    out["climate_pod_work_units"] = static_cast<int64_t>(report.climate_pod_work_units);
    out["climate_pod_changed_cells"] = static_cast<int>(report.climate_pod_changed_cells);
    out["climate_pod_state_hash"] = static_cast<int64_t>(report.climate_pod_state_hash);
    out["climate_pod_reference_hash"] = static_cast<int64_t>(report.climate_pod_reference_hash);
    out["climate_pod_parity_compared"] = report.climate_pod_parity_compared;
    out["climate_pod_parity_matched"] = report.climate_pod_parity_matched;
    out["climate_pod_parity_mismatch_count"] = static_cast<int64_t>(report.climate_pod_parity_mismatch_count);
    out["climate_pod_parity_reason"] = String(report.climate_pod_parity_reason);
    out["climate_parity_day"] = report.climate_parity_day;
    out["climate_parity_stage"] = static_cast<int>(report.climate_parity_stage);
    out["climate_parity_cell"] = static_cast<int>(report.climate_parity_cell);
    out["climate_parity_input_generation"] = static_cast<int64_t>(report.climate_parity_input_generation);
    out["climate_parity_base_generation"] = static_cast<int64_t>(report.climate_parity_base_generation);
    out["climate_parity_trace_hash"] = static_cast<int64_t>(report.climate_parity_trace_hash);
    out["climate_parity_field"] = String(report.climate_parity_field);
    out["climate_parity_reference_bits"] = String(report.climate_parity_reference_bits);
    out["climate_parity_worker_bits"] = String(report.climate_parity_worker_bits);
    out["climate_pod_fallback_reason"] = String(report.climate_pod_fallback_reason);
    out["command_queue_depth"] = static_cast<int>(report.command_queue_depth);
    out["receipt_queue_depth"] = static_cast<int>(report.receipt_queue_depth);
    out["time_debt_days"] = report.time_debt_days;
    out["climate_trace_depth"] = static_cast<int>(report.climate_trace_depth);
    out["climate_trace_front_day"] = report.climate_trace_front_day;
    out["climate_trace_lag_days"] = report.climate_trace_lag_days;
    out["climate_trace_latest_hash"] = static_cast<int64_t>(
        report.climate_trace_latest_hash);
    out["climate_trace_capacity_exceeded"] = static_cast<int64_t>(report.climate_trace_capacity_exceeded);
    out["climate_trace_consumed"] = static_cast<int64_t>(report.climate_trace_consumed);
    out["climate_trace_missing"] = static_cast<int64_t>(report.climate_trace_missing);
    out["climate_trace_captured"] = static_cast<int>(report.climate_trace_captured);
    out["climate_trace_reference_ready"] = static_cast<int>(report.climate_trace_reference_ready);
    out["climate_trace_consumable"] = static_cast<int>(report.climate_trace_consumable);
    out["climate_trace_reference_rejected"] = static_cast<int64_t>(report.climate_trace_reference_rejected);
    out["climate_trace_reference_pending"] = static_cast<int64_t>(report.climate_trace_reference_pending);
    out["executor_workers"] = static_cast<int>(report.executor_workers);
    out["country_pod_snapshot_generation"] = static_cast<int64_t>(report.country_pod_snapshot_generation);
    out["country_pod_state_hash"] = static_cast<int64_t>(report.country_pod_state_hash);
    out["country_pod_work_units"] = static_cast<int64_t>(report.country_pod_work_units);
    out["country_pod_active_country_count"] = static_cast<int>(report.country_pod_active_country_count);
    out["country_pod_active_index_count"] = static_cast<int>(report.country_pod_active_index_count);
    out["country_pod_pending_checks"] = static_cast<int>(report.country_pod_pending_checks);
    out["country_pod_ack_pending"] = report.country_pod_ack_pending;
    out["country_pod_blocker"] = String(report.country_pod_blocker);
    out["country_worker_configured"] = report.country_worker_configured;
    out["country_worker_plan_active"] = report.country_worker_plan_active;
    out["country_worker_waiting_for_peer"] = report.country_worker_waiting_for_peer;
    out["country_worker_pending_intents"] = static_cast<int64_t>(
        report.country_worker_pending_intents);
    out["country_worker_queued_intents"] = static_cast<int64_t>(
        report.country_worker_queued_intents);
    out["country_worker_result_count"] = static_cast<int64_t>(
        report.country_worker_result_count);
    out["country_worker_rejected_results"] = static_cast<int64_t>(
        report.country_worker_rejected_results);
    out["country_worker_session_epoch"] = static_cast<int64_t>(
        report.country_worker_session_epoch);
    out["country_worker_country_generation"] = static_cast<int64_t>(
        report.country_worker_country_generation);
    out["country_worker_day"] = report.country_worker_day;
    out["country_worker_continuation_index"] = static_cast<int64_t>(
        report.country_worker_continuation_index);
    out["country_worker_boundary_id"] = static_cast<int64_t>(
        report.country_worker_boundary_id);
    out["country_worker_last_admitted_submit_order"] = static_cast<int64_t>(
        report.country_worker_last_admitted_submit_order);
    out["country_worker_expected_base_generation"] = static_cast<int64_t>(
        report.country_worker_expected_base_generation);
    out["country_worker_catalog_hash"] = static_cast<int64_t>(
        report.country_worker_catalog_hash);
    out["country_worker_last_reason"] = String(report.country_worker_last_reason);
    out["country_worker_authoritative"] = report.country_worker_authoritative;
    out["country_parity_compared"] = report.country_parity_compared != 0;
    out["country_parity_matched"] = report.country_parity_matched != 0;
    out["country_parity_compared_count"] = static_cast<int64_t>(
        report.country_parity_compared_count);
    out["country_parity_matched_count"] = static_cast<int64_t>(
        report.country_parity_matched_count);
    out["country_parity_status"] = String(report.country_parity_status);
    out["country_parity_first_mismatch_day"] = report.country_parity_first_mismatch_day;
    out["country_parity_reference_hash"] = static_cast<int64_t>(
        report.country_parity_reference_hash);
    out["country_parity_worker_hash"] = static_cast<int64_t>(
        report.country_parity_worker_hash);
    out["country_parity_field"] = String(report.country_parity_field);
    out["country_parity_index"] = report.country_parity_index;
    out["trigger_parity_day"] = report.trigger_parity_day;
    out["trigger_reference_day"] = report.trigger_reference_day;
    out["trigger_input_hash"] = static_cast<int64_t>(report.trigger_input_hash);
    out["trigger_reference_input_hash"] = static_cast<int64_t>(report.trigger_reference_input_hash);
    out["trigger_reference_state_hash"] = static_cast<int64_t>(report.trigger_reference_state_hash);
    out["trigger_worker_state_hash"] = static_cast<int64_t>(report.trigger_worker_state_hash);
    out["trigger_reference_effect_hash"] = static_cast<int64_t>(report.trigger_reference_effect_hash);
    out["trigger_worker_effect_hash"] = static_cast<int64_t>(report.trigger_worker_effect_hash);
    out["trigger_required_ack_count"] = static_cast<int>(report.trigger_required_ack_count);
    out["trigger_received_ack_count"] = static_cast<int>(report.trigger_received_ack_count);
    out["trigger_pending_ack_count"] = static_cast<int>(report.trigger_pending_ack_count);
    out["trigger_generation"] = static_cast<int64_t>(report.trigger_generation);
    out["trigger_committed_day"] = report.trigger_committed_day;
    out["trigger_acked_effect_id"] = report.trigger_acked_effect_id;
    out["trigger_pending_command_count"] = static_cast<int>(report.trigger_pending_command_count);
    out["trigger_parity_compared"] = report.trigger_parity_compared != 0;
    out["trigger_parity_matched"] = report.trigger_parity_matched != 0;
    out["trigger_first_divergence_index"] = report.trigger_first_divergence_index;
    out["trigger_first_divergence_kind"] = String(report.trigger_first_divergence_kind);
    out["trigger_blocker"] = String(report.trigger_blocker);
    out["trigger_pod_ready"] = report.trigger_pod_ready;
    out["trigger_pod_plan_ms"] = report.trigger_pod_plan_ms;
    out["trigger_pod_replay_ms"] = report.trigger_pod_replay_ms;
    out["trigger_pod_state_hash"] = static_cast<int64_t>(report.trigger_pod_state_hash);
    out["trigger_pod_snapshot_generation"] = static_cast<int64_t>(
        report.trigger_pod_snapshot_generation);
    out["trigger_pod_intent_count"] = static_cast<int>(report.trigger_pod_intent_count);
    out["trigger_pod_ack_count"] = static_cast<int>(report.trigger_pod_ack_count);
    out["trigger_pod_fallback_reason"] = String(report.trigger_pod_fallback_reason);
    out["modifier_pod_ready"] = report.modifier_pod_ready;
    out["modifier_pod_plan_ms"] = report.modifier_pod_plan_ms;
    out["modifier_pod_replay_ms"] = report.modifier_pod_replay_ms;
    out["modifier_pod_work_units"] = static_cast<int64_t>(report.modifier_pod_work_units);
    out["modifier_pod_state_hash"] = static_cast<int64_t>(report.modifier_pod_state_hash);
    out["modifier_pod_snapshot_generation"] = static_cast<int64_t>(
        report.modifier_pod_snapshot_generation);
    out["modifier_pod_ack_count"] = static_cast<int>(report.modifier_pod_ack_count);
    out["modifier_pod_fallback_reason"] = String(report.modifier_pod_fallback_reason);
    out["effect_pod_ready"] = report.effect_pod_ready;
    out["effect_pod_plan_ms"] = report.effect_pod_plan_ms;
    out["effect_pod_replay_ms"] = report.effect_pod_replay_ms;
    out["effect_pod_state_hash"] = static_cast<int64_t>(report.effect_pod_state_hash);
    out["effect_pod_snapshot_generation"] = static_cast<int64_t>(
        report.effect_pod_snapshot_generation);
    out["effect_pod_ack_count"] = static_cast<int>(report.effect_pod_ack_count);
    out["effect_pod_intent_count"] = static_cast<int>(report.effect_pod_intent_count);
    out["effect_pod_managed_intent_count"] = static_cast<int>(
        report.effect_pod_managed_intent_count);
    out["effect_pod_unmanaged_intent_count"] = static_cast<int>(
        report.effect_pod_unmanaged_intent_count);
    out["effect_pod_transaction_count"] = static_cast<int>(
        report.effect_pod_transaction_count);
    PackedInt32Array effect_program_ids;
    effect_program_ids.resize(static_cast<int>(
        report.effect_pod_program_intent_count));
    for (uint32_t i = 0; i < report.effect_pod_program_intent_count; ++i) {
        effect_program_ids.set(static_cast<int>(i),
            report.effect_pod_intent_program_ids[i]);
    }
    out["effect_pod_intent_program_ids"] = effect_program_ids;
    out["effect_retire_absent_count"] = static_cast<int64_t>(
        report.effect_retire_absent_count);
    out["effect_retire_stale_count"] = static_cast<int64_t>(
        report.effect_retire_stale_count);
    out["effect_pod_fallback_reason"] = String(report.effect_pod_fallback_reason);
    out["ideology_pod_ready"] = report.ideology_pod_ready;
    out["ideology_pod_plan_ms"] = report.ideology_pod_plan_ms;
    out["ideology_pod_replay_ms"] = report.ideology_pod_replay_ms;
    out["ideology_pod_state_hash"] = static_cast<int64_t>(report.ideology_pod_state_hash);
    out["ideology_pod_snapshot_generation"] = static_cast<int64_t>(
        report.ideology_pod_snapshot_generation);
    out["ideology_pod_pending_transition_count"] = static_cast<int>(
        report.ideology_pod_pending_transition_count);
    out["ideology_pod_intent_count"] = static_cast<int>(report.ideology_pod_intent_count);
    out["ideology_pod_fallback_reason"] = String(report.ideology_pod_fallback_reason);
    out["events_probe_enabled"] = report.events_probe_enabled;
    out["events_pod_ready"] = report.events_pod_ready;
    out["events_pod_plan_ms"] = report.events_pod_plan_ms;
    out["events_pod_replay_ms"] = report.events_pod_replay_ms;
    out["events_pod_state_hash"] = static_cast<int64_t>(report.events_pod_state_hash);
    out["events_pod_snapshot_generation"] = static_cast<int64_t>(
        report.events_pod_snapshot_generation);
    out["events_pod_event_count"] = static_cast<int>(report.events_pod_event_count);
    out["events_pod_ack_count"] = static_cast<int>(report.events_pod_ack_count);
    out["events_pod_drop_count"] = static_cast<int64_t>(report.events_pod_drop_count);
    out["events_pod_rejected_count"] =
        static_cast<int64_t>(report.events_pod_rejected_count);
    out["events_failed_day"] = report.events_failed_day;
    out["events_pod_fallback_reason"] = String(report.events_pod_fallback_reason);
    out["fault_code"] = String(report.fault_code);
    out["fault_injection_armed"] = report.fault_injection_armed;
    out["fault_injection_trip_count"] = static_cast<int64_t>(
        report.fault_injection_trip_count);
    out["fault_injection_point"] = String(report.fault_injection_point);
    return out;
}

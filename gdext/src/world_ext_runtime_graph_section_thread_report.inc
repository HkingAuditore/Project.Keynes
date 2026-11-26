Dictionary DCWorldExt::get_runtime_thread_report() const {
    const NativeParallelExecutor::Report report =
        NativeParallelExecutor::instance().report();
    Dictionary out;
    out["climate_worker_prepares_thermal_equator"] = true;
    out["simulation_executor_exited"] = !_runtime_host || _runtime_host->execution_has_stopped();
    out["executor_serial_only"] = parallel_serial_only();
    out["process_cpu_us"] = process_cpu_us_now();
    if (_runtime_host) {
        const RuntimeThreadReport host = _runtime_host->report();
        out["runtime_domain_abi_version"] = static_cast<int>(host.domain_abi_version);
        out["pod_domain_abi_version"] = static_cast<int>(host.pod_domain_abi_version);
        append_runtime_control_state(out, NativeSimulationHost::ControlState{
            host.state, host.mode, host.authority_ready, report.interactive,
            host.authoritative_domain_mask, host.requested_authority_mask, host.committed_day});
        constexpr std::array<const char *, RuntimeWorkerTiming::MAIN_WAIT_REASON_COUNT> wait_names = {
            "environment_input", "other"};
        Dictionary waits_by_day;
        for (const auto &day : _runtime_host->main_waits_by_day()) {
            if (day.day < 0) continue;
            Dictionary reasons;
            for (size_t i = 0; i < wait_names.size(); ++i) {
                const auto &counter = day.reasons[i];
                if (counter.count == 0) continue;
                Dictionary values;
                values["count"] = static_cast<int64_t>(counter.count);
                values["usec"] = static_cast<int64_t>(counter.usec);
                reasons[wait_names[i]] = values;
            }
            waits_by_day[day.day] = reasons;
        }
        out["worker_main_wait_by_day"] = waits_by_day;
        out["graph_coverage_complete"] = host.graph_coverage_complete;
        out["native_daily_inline"] = host.inline_daily;
        out["inline_day_pending"] = _runtime_host->inline_day_pending();
        out["state_id"] = static_cast<int>(host.state);
        out["domain_abi_version"] = static_cast<int>(host.domain_abi_version);
        out["graph_coverage_state"] = String(host.graph_coverage_state);
        out["required_domain_mask"] = static_cast<int64_t>(host.required_domain_mask);
        out["implemented_domain_mask"] = static_cast<int64_t>(host.implemented_domain_mask);
        out["missing_domain_mask"] = static_cast<int64_t>(host.missing_domain_mask);
        out["completion_gate_missing_domain_mask"] = static_cast<int64_t>(
            host.completion_gate_missing_domain_mask);
        out["active_gate_blocked"] = host.active_gate_blocked;
        out["active_evidence_mask"] =
            static_cast<int64_t>(host.active_evidence_mask);
        // The gate, next to the ledger it is NOT identical to. `suppressed` is what
        // `domain_main_thread_suppressed()` answers, domain by domain; `window` is the
        // part of it held only by the authorization window, i.e. requested but not yet
        // granted. A caller that gates on `authoritative_domain_mask` alone runs
        // domains the product has already stopped -- and one that reads 0 there while
        // the window is open drops the domain it asked for, silently, which is the
        // trap these two masks remove.
        append_main_thread_suppression(*_runtime_host, host, out);
        out["simulation_worker_blocker"] = String(host.coverage_blocker).is_empty()
            ? String(host.fault_code)
            : String(host.coverage_blocker);
        out["input_capture_count"] = static_cast<int64_t>(host.input_capture_count);
        out["input_capture_reused"] = static_cast<int64_t>(host.input_capture_reused);
        out["economy_input_requested_day"] = _runtime_host->economy_input_requested_day();
        out["simulation_generation"] = static_cast<int64_t>(host.generation);
        out["generation"] = static_cast<int64_t>(host.generation);
        out["simulation_state_hash"] = static_cast<int64_t>(host.state_hash);
        out["state_hash"] = static_cast<int64_t>(host.state_hash);
        out["last_commit_produced_at_us"] = static_cast<int64_t>(host.last_commit_produced_at_us);
        out["ui_input_to_feedback_ms"] = host.ui_input_to_feedback_ms;
        out["visual_apply_ms"] = host.visual_apply_ms;
        out["gpu_upload_ms"] = host.gpu_upload_ms;
        append_worker_timing(host.worker_time_us, out);
        out["process_cpu_us"] = process_cpu_us_now();
        out["economy_yield_reason"] = String(host.economy_yield_reason);
        out["economy_stage_name"] = String(host.economy_stage_name);
        out["economy_substage_name"] = String(host.economy_substage_name);
        out["economy_epoch_fiscal_ms"] = host.economy_epoch_fiscal_ms;
        out["economy_fiscal_settlement_ms"] = host.economy_fiscal_settlement_ms;
        out["economy_income_subsidy_ms"] = host.economy_income_subsidy_ms;
        out["economy_negative_tax_mask"] = static_cast<int>(host.economy_negative_tax_mask);
        out["economy_active_tax_mask"] = static_cast<int>(host.economy_active_tax_mask);
        out["economy_attempt_slices"] = static_cast<int>(host.economy_attempt_slices);
        append_economy_read_view_perf(out);
        out["main_wait_on_sim_us"] = static_cast<int64_t>(host.main_wait_on_sim_us);
        out["simulation_environment_generation"] = static_cast<int64_t>(host.environment_generation);
        out["simulation_environment_day"] = host.environment_day;
        out["simulation_environment_cell_count"] = static_cast<int>(host.environment_cell_count);
        out["simulation_environment_topology_validated"] = host.environment_topology_validated;
        out["simulation_invalid_environment_rejected"] = static_cast<int64_t>(host.invalid_environment_rejected);
        out["stale_environment_rejected"] = static_cast<int64_t>(host.stale_environment_rejected);
        out["simulation_time_debt_days"] = host.time_debt_days;
        // Keep the unprefixed spelling available to lightweight callers that
        // consume the direct host report. Both fields describe the same
        // bounded debt value; the prefixed form remains the CSV contract.
        out["time_debt_days"] = host.time_debt_days;
        out["command_queue_capacity_exceeded"] = static_cast<int64_t>(host.command_queue_capacity_exceeded);
        out["receipt_queue_capacity_exceeded"] = static_cast<int64_t>(host.receipt_queue_capacity_exceeded);
        out["worker_fault_count"] = static_cast<int64_t>(host.worker_fault_count);
        out["day_stage_count"] = static_cast<int>(host.day_stage_count);
        out["day_completed_stage_count"] = static_cast<int>(host.day_completed_stage_count);
        out["day_work_units"] = static_cast<int64_t>(host.day_work_units);
        out["completed_days"] = static_cast<int64_t>(host.completed_days);
        out["pod_completed_domain_mask"] = static_cast<int64_t>(host.pod_completed_domain_mask);
        out["pod_completed_stage_count"] = static_cast<int>(host.pod_completed_stage_count);
        out["pod_work_units"] = static_cast<int64_t>(host.pod_work_units);
        out["pod_intent_count"] = static_cast<int>(host.pod_intent_count);
        out["pod_fallback_count"] = static_cast<int>(host.pod_fallback_count);
        out["economy_pod_ready"] = host.economy_pod_ready;
        out["economy_pod_committed"] = host.economy_pod_committed;
        out["economy_pod_authority_ready"] = host.economy_pod_authority_ready;
        out["economy_pod_committed_day"] = host.economy_pod_committed_day;
        out["economy_pod_epoch_sample_day"] = host.economy_pod_epoch_sample_day;
        out["economy_pod_generation"] = static_cast<int64_t>(host.economy_pod_generation);
        out["economy_pod_state_hash"] = static_cast<int64_t>(host.economy_pod_state_hash);
        out["economy_pod_input_generation"] = static_cast<int64_t>(host.economy_pod_input_generation);
        out["economy_pod_country_generation"] = static_cast<int64_t>(host.economy_pod_country_generation);
        out["economy_pod_completed_stage_mask"] = static_cast<int64_t>(host.economy_pod_completed_stage_mask);
        out["economy_pod_pending_outbox"] = static_cast<int>(host.economy_pod_pending_outbox);
        out["economy_pod_pending_inbox"] = static_cast<int>(host.economy_pod_pending_inbox);
        out["economy_pod_operation_gate_mask"] = static_cast<int>(host.economy_pod_operation_gate_mask);
        out["economy_pod_parity_ready_mask"] = static_cast<int>(host.economy_pod_parity_ready_mask);
        out["economy_pod_mirror_feature_mask"] =
            static_cast<int>(host.economy_pod_mirror_feature_mask);
        out["economy_pod_committed_ledger_abi"] =
            static_cast<int>(host.economy_pod_committed_ledger_abi);
        out["economy_pod_active_ready"] = host.economy_pod_active_ready;
        out["economy_authority_switch_count"] = static_cast<int64_t>(
            host.economy_authority_switch_count);
        out["economy_authority_switch_before_hash"] = static_cast<int64_t>(
            host.economy_authority_switch_before_hash);
        out["economy_authority_switch_after_hash"] = static_cast<int64_t>(
            host.economy_authority_switch_after_hash);
        out["economy_authority_switch_latency_us"] = static_cast<int64_t>(
            host.economy_authority_switch_latency_us);
        out["economy_authority_switch_latency_p95_us"] = static_cast<int64_t>(
            host.economy_authority_switch_latency_p95_us);
        out["economy_authority_switch_latency_max_us"] = static_cast<int64_t>(
            host.economy_authority_switch_latency_max_us);
        out["economy_authority_switch_command_latency_us"] = static_cast<int64_t>(
            host.economy_authority_switch_command_latency_us);
        out["economy_authority_switch_command_latency_p95_us"] = static_cast<int64_t>(
            host.economy_authority_switch_command_latency_p95_us);
        out["economy_authority_switch_command_latency_max_us"] = static_cast<int64_t>(
            host.economy_authority_switch_command_latency_max_us);
        out["economy_authority_switch_latency_sample_count"] = static_cast<int64_t>(
            host.economy_authority_switch_latency_sample_count);
        out["economy_authority_switch_rejected"] = static_cast<int64_t>(
            host.economy_authority_switch_rejected);
        out["economy_authority_switch_audit_sequence"] = static_cast<int64_t>(
            host.economy_authority_switch_audit_sequence);
        out["economy_authority_switch_audit_hash"] = static_cast<int64_t>(
            host.economy_authority_switch_audit_hash);
        out["economy_authority_switch_before_generation"] = static_cast<int64_t>(
            host.economy_authority_switch_before_generation);
        out["economy_authority_switch_after_generation"] = static_cast<int64_t>(
            host.economy_authority_switch_after_generation);
        out["economy_authority_fault_paused"] = host.economy_authority_fault_paused;
        out["economy_authority_last_committed_generation"] = static_cast<int64_t>(
            host.economy_authority_last_committed_generation);
        out["economy_authority_last_committed_hash"] = static_cast<int64_t>(
            host.economy_authority_last_committed_hash);
        out["economy_inflight_mutations"] = static_cast<int>(host.economy_inflight_mutations);
        out["worker_day_inflight"] = static_cast<int>(host.worker_day_inflight);
        out["economy_pending_command_count"] = static_cast<int>(host.economy_pending_command_count);
        out["economy_authority_switch_reason"] = String(
            host.economy_authority_switch_reason);
        out["economy_authority_switch_blocker"] = String(
            host.economy_authority_switch_blocker);
        out["economy_authority_switch_audit_before"] = String(
            host.economy_authority_switch_audit_before);
        out["economy_authority_switch_audit_after"] = String(
            host.economy_authority_switch_audit_after);
        out["economy_execution_mode"] = static_cast<int>(host.economy_execution_mode);
        out["economy_execution_mode_name"] = String(
            pk::economy_execution_mode_name(
                static_cast<pk::EconomyExecutionMode>(host.economy_execution_mode)));
        out["economy_shadow_probe_enabled"] = host.economy_shadow_probe_enabled;
        out["economy_shadow_stage_invocations"] =
            static_cast<int64_t>(host.economy_shadow_stage_invocations);
        out["economy_shadow_stage_cache_hits"] =
            static_cast<int64_t>(host.economy_shadow_stage_cache_hits);
        out["economy_stage_ops_mutate"] = host.economy_stage_ops_mutate;
        out["economy_auto_pod_active"] = host.economy_auto_pod_active;
        out["economy_pod_command_recapture_count"] =
            static_cast<int64_t>(host.economy_pod_command_recapture_count);
        out["economy_pod_command_verify_count"] =
            static_cast<int64_t>(host.economy_pod_command_verify_count);
        out["economy_formula_backing"] = String(host.economy_formula_backing);
        out["economy_production_writer"] = String(host.economy_production_writer);
        out["economy_production_writer_requested"] =
            String(host.economy_production_writer_requested);
        out["economy_production_writer_effective"] =
            String(host.economy_production_writer_effective);
        out["economy_stage_ops_readiness_mask"] =
            static_cast<int64_t>(host.economy_stage_ops_readiness_mask);
        out["economy_stage_ops_prelude_ready"] =
            host.economy_stage_ops_prelude_ready;
        out["economy_stage_ops_soak_experiment"] =
            host.economy_stage_ops_soak_experiment;
        out["economy_stage_ops_soak_parity_ok"] =
            host.economy_stage_ops_soak_parity_ok;
        out["economy_replay_completed_stage_mask"] = static_cast<int64_t>(host.economy_replay_completed_stage_mask);
        out["economy_replay_stage_cursor"] = static_cast<int>(host.economy_replay_stage_cursor);
        out["economy_replay_input_hash"] = static_cast<int64_t>(host.economy_replay_input_hash);
        out["economy_replay_base_hash"] = static_cast<int64_t>(host.economy_replay_base_hash);
        out["economy_replay_next_hash"] = static_cast<int64_t>(host.economy_replay_next_hash);
        out["economy_replay_input_captured"] = host.economy_replay_input_captured;
        out["economy_replay_committed"] = host.economy_replay_committed;
        out["economy_replay_parity_ready"] = host.economy_replay_parity_ready;
        out["economy_replay_fallback_reason"] = String(host.economy_replay_fallback_reason);
        PackedInt64Array replay_hashes;
        PackedInt64Array replay_work;
        PackedFloat64Array replay_ms;
        replay_hashes.resize(static_cast<int>(pk::RUNTIME_ECONOMY_GRAPH_STAGE_COUNT));
        replay_work.resize(static_cast<int>(pk::RUNTIME_ECONOMY_GRAPH_STAGE_COUNT));
        replay_ms.resize(static_cast<int>(pk::RUNTIME_ECONOMY_GRAPH_STAGE_COUNT));
        for (int i = 0; i < static_cast<int>(pk::RUNTIME_ECONOMY_GRAPH_STAGE_COUNT); ++i) {
            replay_hashes.set(i, static_cast<int64_t>(host.economy_replay_stage_hash[i]));
            replay_work.set(i, static_cast<int64_t>(host.economy_replay_stage_work[i]));
            replay_ms.set(i, host.economy_replay_stage_ms[i]);
        }
        out["economy_replay_stage_hash"] = replay_hashes;
        out["economy_replay_stage_work"] = replay_work;
        out["economy_replay_stage_ms"] = replay_ms;
        out["domain_authority_planned_mask"] = static_cast<int64_t>(
            host.domain_authority_planned_mask);
        out["domain_authority_committed_mask"] = static_cast<int64_t>(
            host.domain_authority_committed_mask);
        out["domain_authority_ack_count"] = static_cast<int>(
            host.domain_authority_ack_count);
        out["domain_authority_input_hash"] = static_cast<int64_t>(
            host.domain_authority_input_hash);
        out["domain_authority_state_hash"] = static_cast<int64_t>(
            host.domain_authority_state_hash);
        out["domain_authority_plan_ms"] = host.domain_authority_plan_ms;
        out["domain_authority_replay_ms"] = host.domain_authority_replay_ms;
        out["domain_authority_fallback_reason"] = String(
            host.domain_authority_fallback_reason);
        out["domain_stage_fallback_count"] = static_cast<int>(
            host.domain_stage_fallback_count);
        out["domain_stage_fallback_reason"] = String(
            host.domain_stage_fallback_reason);
        // Climate POD remains SHADOW-only diagnostic work. Keep the direct
        // thread report aligned with get_runtime_perf_snapshot() so callers
        // do not infer its availability from which facade they queried.
        out["climate_pod_ready"] = host.climate_pod_ready;
        out["climate_pod_plan_ms"] = host.climate_pod_plan_ms;
        out["climate_pod_replay_ms"] = host.climate_pod_replay_ms;
        out["climate_pod_work_units"] = static_cast<int64_t>(host.climate_pod_work_units);
        out["climate_pod_changed_cells"] = static_cast<int>(host.climate_pod_changed_cells);
        append_climate_stage_cadence(out, host);
        out["climate_pod_state_hash"] = static_cast<int64_t>(host.climate_pod_state_hash);
        out["climate_pod_reference_hash"] = static_cast<int64_t>(
            host.climate_pod_reference_hash);
        out["climate_pod_parity_compared"] = host.climate_pod_parity_compared;
        out["climate_pod_parity_matched"] = host.climate_pod_parity_matched;
        out["climate_pod_parity_mismatch_count"] = static_cast<int64_t>(
            host.climate_pod_parity_mismatch_count);
        out["climate_pod_parity_reason"] = String(host.climate_pod_parity_reason);
        out["climate_pod_fallback_reason"] = String(host.climate_pod_fallback_reason);
        // 首差异槽位（S2）。少了它们，逐日报告只能说"这天不匹配"，说不出是哪个
        // 字段哪个 cell——而这正是 harness 唯一能定位分叉的信息。
        out["climate_parity_day"] = host.climate_parity_day;
        out["climate_parity_stage"] = static_cast<int>(host.climate_parity_stage);
        out["climate_parity_cell"] = static_cast<int>(host.climate_parity_cell);
        out["climate_parity_input_generation"] = static_cast<int64_t>(
            host.climate_parity_input_generation);
        out["climate_parity_base_generation"] = static_cast<int64_t>(
            host.climate_parity_base_generation);
        out["climate_parity_trace_hash"] = static_cast<int64_t>(
            host.climate_parity_trace_hash);
        out["climate_parity_field"] = String(host.climate_parity_field);
        out["climate_parity_reference_bits"] = String(
            host.climate_parity_reference_bits);
        out["climate_parity_worker_bits"] = String(host.climate_parity_worker_bits);
        // 生产 / worker 各跑过哪些 stage（1 << RuntimeClimateStage）。差集是分叉矩阵
        // 里 stage 9..13 那些字段唯一可信的归因来源。
        out["climate_production_stage_mask"] =
            static_cast<int>(host.climate_production_stage_mask);
        out["climate_worker_stage_mask"] =
            static_cast<int>(host.climate_worker_stage_mask);
        // B8-2：worker 自持 cyclone 的当日事实（soak/C3 的 JSON 证据来源）。
        out["climate_cyclone_alive"] = static_cast<int>(host.climate_cyclone_alive);
        out["climate_cyclone_injected"] =
            static_cast<int>(host.climate_cyclone_injected);
        out["climate_cyclone_replaced"] =
            static_cast<int>(host.climate_cyclone_replaced);
        out["climate_cyclone_decayed"] =
            static_cast<int>(host.climate_cyclone_decayed);
        out["climate_cyclone_touched"] =
            static_cast<int>(host.climate_cyclone_touched);
        // B8 P0：交付游标。见 RuntimeThreadReport 的注释 —— 这组数字把
        // "worker 慢"（consumed 落后 published）与"输入被覆盖"（superseded）
        // 分开，是背压策略与 50/50 验收的判据。
        out["climate_committed_day"] = host.climate_committed_day;
        out["climate_consumed_generation"] =
            static_cast<int64_t>(host.climate_consumed_generation);
        out["environment_published_days"] =
            static_cast<int64_t>(host.environment_published_days);
        out["environment_consumed_days"] =
            static_cast<int64_t>(host.environment_consumed_days);
        out["environment_superseded_days"] =
            static_cast<int64_t>(host.environment_superseded_days);
        out["environment_dropped_days"] =
            static_cast<int64_t>(host.environment_dropped_days);
        out["environment_ring_pending"] =
            static_cast<int64_t>(host.environment_ring_pending);
        out["day_stall_reason_mask"] =
            static_cast<int64_t>(host.day_stall_reason_mask);
        out["day_stall_day"] = host.day_stall_day;
        // Day-plan gap: which domain stage is still unfinished for the worker's
        // current day. Reported separately from day_stall_* because a missing
        // stage with no stall bit produces no diagnostic anywhere else.
        out["day_wait_day"] = host.day_wait_day;
        out["day_wait_missing_mask"] = static_cast<int64_t>(host.day_wait_missing_mask);
        out["day_wait_env_day"] = host.day_wait_env_day;
        out["day_wait_ring"] = static_cast<int64_t>(host.day_wait_ring);
        // Which domain parked the day and on which line. The park branches are
        // deliberately non-fatal, so this is the only attribution they have.
        out["day_park_domain_mask"] = static_cast<int64_t>(host.day_park_domain_mask);
        out["day_park_reason"] = String(host.day_park_reason);
        out["effect_instance_rejected_count"] =
            static_cast<int64_t>(host.effect_instance_rejected_count);
        out["effect_instance_reject_detail"] = String(
            host.effect_instance_reject_detail);
        out["day_stall_peer_ms"] =
            static_cast<int64_t>(host.day_stall_peer_ms);
        out["climate_wait_total_ms"] =
            static_cast<int64_t>(host.climate_wait_total_ms);
        out["climate_wait_last_ms"] =
            static_cast<int64_t>(host.climate_wait_last_ms);
        out["climate_wait_max_ms"] =
            static_cast<int64_t>(host.climate_wait_max_ms);
        out["climate_trace_depth"] = static_cast<int>(host.climate_trace_depth);
        out["climate_trace_front_day"] = host.climate_trace_front_day;
        out["climate_trace_lag_days"] = host.climate_trace_lag_days;
        out["climate_trace_latest_hash"] = static_cast<int64_t>(host.climate_trace_latest_hash);
        out["climate_trace_consumed"] = static_cast<int64_t>(host.climate_trace_consumed);
        out["climate_trace_missing"] = static_cast<int64_t>(host.climate_trace_missing);
        out["climate_trace_captured"] = static_cast<int>(host.climate_trace_captured);
        out["climate_trace_reference_ready"] = static_cast<int>(
            host.climate_trace_reference_ready);
        out["climate_trace_consumable"] = static_cast<int>(
            host.climate_trace_consumable);
        out["climate_trace_reference_rejected"] = static_cast<int64_t>(
            host.climate_trace_reference_rejected);
        out["climate_trace_reference_pending"] = static_cast<int64_t>(
            host.climate_trace_reference_pending);
        out["climate_trace_capacity_exceeded"] = static_cast<int64_t>(
            host.climate_trace_capacity_exceeded);
        out["climate_trace_lag_days"] = host.climate_trace_lag_days;
        out["worker_fault_count"] = static_cast<int64_t>(host.worker_fault_count);
        out["coverage_blocker"] = String(host.coverage_blocker);
        out["fault_code"] = String(host.fault_code);
        out["simulation_invalid_environment_rejected"] = static_cast<int64_t>(host.invalid_environment_rejected);
        out["country_pod_snapshot_generation"] = static_cast<int64_t>(host.country_pod_snapshot_generation);
        out["country_pod_state_hash"] = static_cast<int64_t>(host.country_pod_state_hash);
        out["country_pod_work_units"] = static_cast<int64_t>(host.country_pod_work_units);
        out["country_pod_active_country_count"] = static_cast<int>(host.country_pod_active_country_count);
        out["country_pod_active_index_count"] = static_cast<int>(host.country_pod_active_index_count);
        out["country_pod_pending_checks"] = static_cast<int>(host.country_pod_pending_checks);
        out["country_pod_ack_pending"] = host.country_pod_ack_pending;
        out["country_pod_blocker"] = String(host.country_pod_blocker);
        out["country_worker_configured"] = host.country_worker_configured;
        out["country_worker_plan_active"] = host.country_worker_plan_active;
        out["country_worker_waiting_for_peer"] = host.country_worker_waiting_for_peer;
        out["country_worker_pending_intents"] = static_cast<int64_t>(
            host.country_worker_pending_intents);
        out["country_worker_queued_intents"] = static_cast<int64_t>(
            host.country_worker_queued_intents);
        out["country_worker_result_count"] = static_cast<int64_t>(
            host.country_worker_result_count);
        out["country_worker_rejected_results"] = static_cast<int64_t>(
            host.country_worker_rejected_results);
        out["country_worker_session_epoch"] = static_cast<int64_t>(
            host.country_worker_session_epoch);
        out["country_worker_country_generation"] = static_cast<int64_t>(
            host.country_worker_country_generation);
        out["country_worker_day"] = host.country_worker_day;
        out["country_worker_continuation_index"] = static_cast<int64_t>(
            host.country_worker_continuation_index);
        out["country_worker_boundary_id"] = static_cast<int64_t>(
            host.country_worker_boundary_id);
        out["country_worker_last_admitted_submit_order"] = static_cast<int64_t>(
            host.country_worker_last_admitted_submit_order);
        out["country_worker_expected_base_generation"] = static_cast<int64_t>(
            host.country_worker_expected_base_generation);
        out["country_worker_catalog_hash"] = static_cast<int64_t>(
            host.country_worker_catalog_hash);
        out["country_worker_last_reason"] = String(host.country_worker_last_reason);
        out["country_worker_authoritative"] = host.country_worker_authoritative;
        out["modifier_worker_authoritative"] =
            (host.authoritative_domain_mask &
             runtime_domain_mask(RuntimeDomainId::MODIFIER)) != 0u;
        out["effect_worker_authoritative"] =
            (host.authoritative_domain_mask &
             runtime_domain_mask(RuntimeDomainId::EFFECT)) != 0u;
        out["ideology_worker_authoritative"] =
            (host.authoritative_domain_mask &
             runtime_domain_mask(RuntimeDomainId::IDEOLOGY)) != 0u;
        out["trigger_worker_authoritative"] =
            (host.authoritative_domain_mask &
             runtime_domain_mask(RuntimeDomainId::TRIGGER_INPUT)) != 0u;
        // I8: the Events grant means the worker mirrors the committed journal in
        // POD form and owns the EVENTS stage bit. The legacy GameplayEventBus
        // journal is still the production consumer source.
        out["events_worker_authoritative"] =
            (host.authoritative_domain_mask &
             runtime_domain_mask(RuntimeDomainId::EVENTS)) != 0u;
        out["country_parity_compared"] = host.country_parity_compared != 0;
        out["country_parity_matched"] = host.country_parity_matched != 0;
        out["country_parity_compared_count"] = static_cast<int64_t>(
            host.country_parity_compared_count);
        out["country_parity_matched_count"] = static_cast<int64_t>(
            host.country_parity_matched_count);
        out["country_parity_status"] = String(host.country_parity_status);
        out["country_parity_first_mismatch_day"] =
            host.country_parity_first_mismatch_day;
        out["country_parity_reference_hash"] = static_cast<int64_t>(
            host.country_parity_reference_hash);
        out["country_parity_worker_hash"] = static_cast<int64_t>(
            host.country_parity_worker_hash);
        out["country_parity_field"] = String(host.country_parity_field);
        out["ideology_parity_compared"] = host.ideology_parity_compared;
        out["ideology_parity_matched"] = host.ideology_parity_matched;
        out["ideology_parity_compared_count"] = host.ideology_parity_compared_count;
        out["ideology_parity_matched_count"] = host.ideology_parity_matched_count;
        out["ideology_parity_reference_hash"] =
            static_cast<int64_t>(host.ideology_parity_reference_hash);
        out["ideology_parity_worker_hash"] =
            static_cast<int64_t>(host.ideology_parity_worker_hash);
        out["ideology_parity_first_mismatch_day"] =
            host.ideology_parity_first_mismatch_day;
        out["ideology_parity_uncompared_day_offset"] =
            host.ideology_parity_uncompared_day_offset;
        out["ideology_parity_field"] = String(host.ideology_parity_field);
        // Reference-publish ledger, always exported. A caller must be able to tell
        // "nothing was ever compared" apart from "compared and disagreed", and
        // "the reference was refused because the main thread had no rows" apart
        // from "the reference was published". Without these three the only
        // visible symptom of main-thread starvation was `field=points`.
        out["ideology_parity_reference_publish_count"] =
            host.ideology_parity_reference_publish_count;
        out["ideology_parity_reference_published_day"] =
            host.ideology_parity_reference_published_day;
        out["ideology_parity_reference_published_countries"] =
            host.ideology_parity_reference_published_countries;
        out["ideology_parity_reference_published_with_points_revision"] =
            host.ideology_parity_reference_published_with_points_revision;
        out["ideology_parity_reference_skipped_count"] =
            host.ideology_parity_reference_skipped_count;
        out["ideology_parity_reference_skip_reason"] =
            String(host.ideology_parity_reference_skip_reason);
        // Precondition, not a business divergence: the two sides hash the
        // catalog with different functions, so equality is never expected.
        out["ideology_parity_catalog_mismatch_count"] =
            host.ideology_parity_catalog_mismatch_count;
        out["ideology_parity_last_reference_catalog_hash"] =
            host.ideology_parity_last_reference_catalog_hash;
        out["ideology_parity_last_worker_catalog_hash"] =
            host.ideology_parity_last_worker_catalog_hash;
        out["ideology_parity_worker_opinion_revision"] =
            host.ideology_parity_worker_opinion_revision;
        out["ideology_parity_worker_committed_day"] =
            host.ideology_parity_worker_committed_day;
        out["ideology_parity_worker_opinion_period_index"] =
            host.ideology_parity_worker_opinion_period_index;
        out["ideology_parity_worker_opinion_committed_day"] =
            host.ideology_parity_worker_opinion_committed_day;
        out["ideology_parity_paired_reference_day"] =
            host.ideology_parity_paired_reference_day;
        out["ideology_parity_paired_worker_day"] =
            host.ideology_parity_paired_worker_day;
        out["ideology_parity_row_mismatch_slot"] =
            host.ideology_parity_row_mismatch_slot;
        out["ideology_parity_row_mismatch_reference_handle"] =
            host.ideology_parity_row_mismatch_reference_handle;
        out["ideology_parity_row_mismatch_worker_handle"] =
            host.ideology_parity_row_mismatch_worker_handle;
        out["ideology_parity_row_mismatch_reference_points"] =
            host.ideology_parity_row_mismatch_reference_points;
        out["ideology_parity_row_mismatch_worker_points"] =
            host.ideology_parity_row_mismatch_worker_points;
        if (host.ideology_parity_points_diff_valid) {
            Dictionary diff;
            diff["day"] = host.ideology_parity_points_diff_day;
            diff["slot"] = host.ideology_parity_points_diff_slot;
            diff["reference_countries"] = host.ideology_parity_points_diff_reference_countries;
            diff["worker_countries"] = host.ideology_parity_points_diff_worker_countries;
            diff["handle"] = host.ideology_parity_points_diff_handle;
            diff["reference_handle"] = host.ideology_parity_points_diff_reference_handle;
            diff["worker_handle"] = host.ideology_parity_points_diff_worker_handle;
            diff["reference_points_q16"] = host.ideology_parity_points_diff_reference_points_q16;
            diff["worker_points_q16"] = host.ideology_parity_points_diff_worker_points_q16;
            diff["reference_lifetime_q16"] = host.ideology_parity_points_diff_reference_lifetime_q16;
            diff["worker_lifetime_q16"] = host.ideology_parity_points_diff_worker_lifetime_q16;
            diff["reference_revision"] = host.ideology_parity_points_diff_reference_revision;
            diff["worker_revision"] = host.ideology_parity_points_diff_worker_revision;
            diff["reference_baseline_ready"] = host.ideology_parity_points_diff_reference_baseline_ready;
            diff["worker_baseline_ready"] = host.ideology_parity_points_diff_worker_baseline_ready;
            diff["reference_baseline_population"] = host.ideology_parity_points_diff_reference_baseline_population;
            diff["worker_baseline_population"] = host.ideology_parity_points_diff_worker_baseline_population;
            diff["reference_baseline_buildings"] = host.ideology_parity_points_diff_reference_baseline_buildings;
            diff["worker_baseline_buildings"] = host.ideology_parity_points_diff_worker_baseline_buildings;
            diff["reference_history_count"] = host.ideology_parity_points_diff_reference_history_count;
            diff["worker_history_count"] = host.ideology_parity_points_diff_worker_history_count;
            diff["reference_history_head"] = host.ideology_parity_points_diff_reference_history_head;
            diff["worker_history_head"] = host.ideology_parity_points_diff_worker_history_head;
            {
                godot::Array ref_hist;
                godot::Array worker_hist;
                for (size_t i = 0; i < host.ideology_parity_points_diff_reference_history_q16.size(); ++i)
                    ref_hist.push_back(host.ideology_parity_points_diff_reference_history_q16[i]);
                for (size_t i = 0; i < host.ideology_parity_points_diff_worker_history_q16.size(); ++i)
                    worker_hist.push_back(host.ideology_parity_points_diff_worker_history_q16[i]);
                diff["reference_history_q16"] = ref_hist;
                diff["worker_history_q16"] = worker_hist;
            }
            diff["reference_last_day"] = host.ideology_parity_points_diff_reference_last_day;
            diff["worker_round_day"] = host.ideology_parity_points_diff_worker_round_day;
            diff["worker_committed_day"] = host.ideology_parity_points_diff_worker_committed_day;
            diff["reference_catalog_hash"] = host.ideology_parity_points_diff_reference_catalog_hash;
            diff["worker_catalog_hash"] = host.ideology_parity_points_diff_worker_catalog_hash;
            diff["reference_publish_count"] = host.ideology_parity_reference_publish_count;
            diff["reference_published_day"] = host.ideology_parity_reference_published_day;
            diff["reference_published_countries"] = host.ideology_parity_reference_published_countries;
            diff["reference_published_with_points_revision"] = host.ideology_parity_reference_published_with_points_revision;
            diff["reference_skipped_count"] = host.ideology_parity_reference_skipped_count;
            diff["reference_skip_reason"] = String(host.ideology_parity_reference_skip_reason);
            out["ideology_parity_points_diff"] = diff;
        }
        out["country_parity_index"] = host.country_parity_index;
        out["trigger_parity_day"] = host.trigger_parity_day;
        out["trigger_reference_day"] = host.trigger_reference_day;
        out["trigger_input_hash"] = static_cast<int64_t>(host.trigger_input_hash);
        out["trigger_reference_input_hash"] = static_cast<int64_t>(host.trigger_reference_input_hash);
        out["trigger_reference_state_hash"] = static_cast<int64_t>(host.trigger_reference_state_hash);
        out["trigger_worker_state_hash"] = static_cast<int64_t>(host.trigger_worker_state_hash);
        out["trigger_reference_effect_hash"] = static_cast<int64_t>(host.trigger_reference_effect_hash);
        out["trigger_worker_effect_hash"] = static_cast<int64_t>(host.trigger_worker_effect_hash);
        out["trigger_required_ack_count"] = static_cast<int>(host.trigger_required_ack_count);
        out["trigger_received_ack_count"] = static_cast<int>(host.trigger_received_ack_count);
        out["trigger_pending_ack_count"] = static_cast<int>(host.trigger_pending_ack_count);
        out["trigger_generation"] = static_cast<int64_t>(host.trigger_generation);
        out["trigger_committed_day"] = host.trigger_committed_day;
        out["trigger_acked_effect_id"] = host.trigger_acked_effect_id;
        out["trigger_pending_command_count"] = static_cast<int>(host.trigger_pending_command_count);
        out["trigger_parity_compared"] = host.trigger_parity_compared != 0;
        out["trigger_parity_matched"] = host.trigger_parity_matched != 0;
        out["trigger_first_divergence_index"] = host.trigger_first_divergence_index;
        out["trigger_first_divergence_kind"] = String(host.trigger_first_divergence_kind);
        out["trigger_blocker"] = String(host.trigger_blocker);
        out["trigger_pod_ready"] = host.trigger_pod_ready;
        out["trigger_pod_plan_ms"] = host.trigger_pod_plan_ms;
        out["trigger_pod_replay_ms"] = host.trigger_pod_replay_ms;
        out["trigger_pod_state_hash"] = static_cast<int64_t>(
            host.trigger_pod_state_hash);
        out["trigger_pod_snapshot_generation"] = static_cast<int64_t>(
            host.trigger_pod_snapshot_generation);
        out["trigger_pod_intent_count"] = static_cast<int>(
            host.trigger_pod_intent_count);
        out["trigger_pod_ack_count"] = static_cast<int>(
            host.trigger_pod_ack_count);
        out["trigger_pod_fallback_reason"] = String(
            host.trigger_pod_fallback_reason);
        out["modifier_pod_ready"] = host.modifier_pod_ready;
        out["modifier_pod_plan_ms"] = host.modifier_pod_plan_ms;
        out["modifier_pod_replay_ms"] = host.modifier_pod_replay_ms;
        out["modifier_pod_work_units"] = static_cast<int64_t>(
            host.modifier_pod_work_units);
        out["modifier_pod_state_hash"] = static_cast<int64_t>(
            host.modifier_pod_state_hash);
        out["modifier_pod_snapshot_generation"] = static_cast<int64_t>(
            host.modifier_pod_snapshot_generation);
        out["modifier_pod_ack_count"] = static_cast<int>(
            host.modifier_pod_ack_count);
        out["modifier_pod_fallback_reason"] = String(
            host.modifier_pod_fallback_reason);
        out["effect_pod_ready"] = host.effect_pod_ready;
        out["effect_pod_plan_ms"] = host.effect_pod_plan_ms;
        out["effect_pod_replay_ms"] = host.effect_pod_replay_ms;
        out["effect_pod_state_hash"] = static_cast<int64_t>(
            host.effect_pod_state_hash);
        out["effect_pod_snapshot_generation"] = static_cast<int64_t>(
            host.effect_pod_snapshot_generation);
        out["effect_pod_ack_count"] = static_cast<int>(
            host.effect_pod_ack_count);
        out["effect_pod_intent_count"] = static_cast<int>(
            host.effect_pod_intent_count);
        out["effect_pod_managed_intent_count"] = static_cast<int>(
            host.effect_pod_managed_intent_count);
        out["effect_pod_unmanaged_intent_count"] = static_cast<int>(
            host.effect_pod_unmanaged_intent_count);
        out["effect_pod_transaction_count"] = static_cast<int>(
            host.effect_pod_transaction_count);
        PackedInt32Array effect_program_ids;
        effect_program_ids.resize(static_cast<int>(
            host.effect_pod_program_intent_count));
        for (uint32_t i = 0; i < host.effect_pod_program_intent_count; ++i) {
            effect_program_ids.set(static_cast<int>(i),
                host.effect_pod_intent_program_ids[i]);
        }
        out["effect_pod_intent_program_ids"] = effect_program_ids;
        out["effect_retire_absent_count"] = static_cast<int64_t>(
            host.effect_retire_absent_count);
        out["effect_retire_stale_count"] = static_cast<int64_t>(
            host.effect_retire_stale_count);
        out["effect_pod_fallback_reason"] = String(
            host.effect_pod_fallback_reason);
        out["ideology_pod_ready"] = host.ideology_pod_ready;
        out["ideology_pod_plan_ms"] = host.ideology_pod_plan_ms;
        out["ideology_pod_replay_ms"] = host.ideology_pod_replay_ms;
        out["ideology_pod_state_hash"] = static_cast<int64_t>(
            host.ideology_pod_state_hash);
        out["ideology_pod_snapshot_generation"] = static_cast<int64_t>(
            host.ideology_pod_snapshot_generation);
        out["ideology_pod_pending_transition_count"] = static_cast<int>(
            host.ideology_pod_pending_transition_count);
        out["ideology_pod_intent_count"] = static_cast<int>(
            host.ideology_pod_intent_count);
        out["ideology_opinion_wait_days"] = static_cast<int>(
            host.ideology_opinion_wait_days);
        // The day the worker last committed IDEOLOGY for.
        //
        // `RuntimeThreadReport` has carried `worker_committed_ideology_day` since the
        // POD landed, but nothing ever copied it into this Dictionary, so GDScript had
        // no way to observe it. Tests did the only thing left and polled a key that
        // never existed (`ideology_pod_committed_day`), which is why every
        // "wait for the worker to finish a day" loop silently burned its whole timeout
        // and then asserted on a stale snapshot.
        //
        // `ideology_parity_worker_committed_day` is NOT a substitute: it is only
        // assigned while a parity reference is being recorded, so a production session
        // (and this fixture, which never completes a parity day) leaves it at -1.
        out["ideology_pod_committed_day"] = host.ideology_pod_committed_day;
        out["ideology_pod_fallback_reason"] = String(
            host.ideology_pod_fallback_reason);
        out["events_probe_enabled"] = host.events_probe_enabled;
        out["events_pod_ready"] = host.events_pod_ready;
        out["events_pod_plan_ms"] = host.events_pod_plan_ms;
        out["events_pod_replay_ms"] = host.events_pod_replay_ms;
        out["events_pod_state_hash"] = static_cast<int64_t>(
            host.events_pod_state_hash);
        out["events_pod_snapshot_generation"] = static_cast<int64_t>(
            host.events_pod_snapshot_generation);
        out["events_pod_event_count"] = static_cast<int>(
            host.events_pod_event_count);
        out["events_pod_ack_count"] = static_cast<int>(
            host.events_pod_ack_count);
        out["events_pod_drop_count"] = static_cast<int64_t>(
            host.events_pod_drop_count);
        out["events_pod_rejected_count"] = static_cast<int64_t>(
            host.events_pod_rejected_count);
        out["events_failed_day"] = host.events_failed_day;
        out["events_pod_fallback_reason"] = String(
            host.events_pod_fallback_reason);
        out["command_queue_depth"] = static_cast<int>(host.command_queue_depth);
        out["receipt_queue_depth"] = static_cast<int>(host.receipt_queue_depth);
    } else {
        out["runtime_domain_abi_version"] = static_cast<int>(RUNTIME_DOMAIN_ABI_VERSION);
        out["pod_domain_abi_version"] = static_cast<int>(RUNTIME_DOMAIN_POD_ABI_VERSION);
        NativeSimulationHost::ControlState control;
        control.interactive = report.interactive;
        append_runtime_control_state(out, control);
        out["native_daily_inline"] = false;
        out["graph_coverage_state"] = "partial";
        out["required_domain_mask"] = static_cast<int64_t>(RUNTIME_ALL_DOMAIN_MASK);
        out["implemented_domain_mask"] = 0;
        out["missing_domain_mask"] = static_cast<int64_t>(RUNTIME_ALL_DOMAIN_MASK);
        out["active_evidence_mask"] = 0;
        out["simulation_worker_blocker"] =
            "runtime_graph_still_uses_godot_containers_and_object_boundaries";
    }
    out["executor_backend"] = "native_fixed_pool";
    out["hardware_threads"] = static_cast<int64_t>(report.hardware_threads);
    out["worker_threads"] = static_cast<int64_t>(report.worker_threads);
    out["active_worker_limit"] =
        static_cast<int64_t>(report.active_worker_limit);
    out["dispatch_count"] = static_cast<int64_t>(report.dispatch_count);
    out["serial_dispatch_count"] =
        static_cast<int64_t>(report.serial_dispatch_count);
    out["task_count"] = static_cast<int64_t>(report.task_count);
    out["fault_count"] = static_cast<int64_t>(report.fault_count);
    out["thread_priority"] = "below_normal_windows";
    return out;
}

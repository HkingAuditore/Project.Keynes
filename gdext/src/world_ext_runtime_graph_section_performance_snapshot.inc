Dictionary DCWorldExt::get_runtime_perf_snapshot(int detail_level) const {
    Dictionary out;
    out["configured"] = _runtime_graph_configured;
    out["enabled"] = _runtime_graph_enabled;
    out["simulation_thread_mode"] = String("OFF");
    // native_daily_inline：键恒定存在，调用方不必猜"缺失=false"。
    out["native_daily_inline"] = false;
    out["graph_coverage_state"] = String("partial");
    out["simulation_worker_ready"] = false;
    out["pod_domain_abi_version"] = static_cast<int>(RUNTIME_DOMAIN_POD_ABI_VERSION);
    out["pod_completed_domain_mask"] = 0;
    out["pod_completed_stage_count"] = 0;
    out["pod_work_units"] = 0;
    out["pod_intent_count"] = 0;
    out["pod_fallback_count"] = 0;
    out["domain_authority_planned_mask"] = 0;
    out["domain_authority_committed_mask"] = 0;
    out["domain_authority_ack_count"] = 0;
    out["domain_authority_input_hash"] = 0;
    out["domain_authority_state_hash"] = 0;
    out["domain_authority_plan_ms"] = 0.0;
    out["domain_authority_replay_ms"] = 0.0;
    out["domain_authority_fallback_reason"] = String();
    // P0：这五个键恒定存在。缺键会让调用方把"没有 host"读成"worker 起来了"，
    // 而这个区别正是 web 上要判的东西。
    out["graph_coverage_complete"] = false;
    out["requested_authority_mask"] = 0;
    out["worker_thread_create_failed"] = false;
    out["day_wait_day"] = -1;
    out["day_wait_missing_mask"] = 0;
    out["day_wait_env_day"] = -1;
    out["day_wait_ring"] = 0;
    out["environment_ring_pending"] = 0;
    out["environment_frames_ahead"] = 0;
    out["country_peer_resolved_in_worker"] = 0;
    out["country_peer_resolved_by_main"] = 0;
    if (_runtime_host) {
        const RuntimeThreadReport host = _runtime_host->report();
        out["simulation_thread_mode"] = runtime_effective_mode_name(
            host.mode, host.authority_ready, host.authoritative_domain_mask);
        out["requested_simulation_thread_mode"] =
            host.mode == RuntimeSimulationMode::ACTIVE ? "ACTIVE" :
            host.mode == RuntimeSimulationMode::SHADOW ? "SHADOW" : "OFF";
        out["native_daily_inline"] = host.inline_daily;
        out["graph_coverage_state"] = String(host.graph_coverage_state);
        out["simulation_host_state"] = static_cast<int>(host.state);
        out["worker_fault_count"] = static_cast<int64_t>(host.worker_fault_count);
        out["fault_code"] = String(host.fault_code);
        out["simulation_worker_ready"] =
            host.authority_ready || host.authoritative_domain_mask != 0u;
        out["required_domain_mask"] = static_cast<int64_t>(host.required_domain_mask);
        out["implemented_domain_mask"] = static_cast<int64_t>(host.implemented_domain_mask);
        out["missing_domain_mask"] = static_cast<int64_t>(host.missing_domain_mask);
        out["completion_gate_missing_domain_mask"] = static_cast<int64_t>(
            host.completion_gate_missing_domain_mask);
        out["active_gate_blocked"] = host.active_gate_blocked;
        // ── P0：让 web 上能直接看出 worker 为什么起不来 / 被降级 ──────────
        // 这几项与 get_runtime_thread_report() 同名同义，放进 perf snapshot 是
        // 为了让"只读一个字典"的诊断（diag 事件、perf CSV、forensics）不必再猜
        // 该去哪张表里找。`worker_thread_create_failed` 是把 fault_code 里那条
        // 具体 code 提升成布尔位：std::thread 真的创建失败与"被入门门挡下"是
        // 两种完全不同的处置，混在同一个空 fault 里看不出来。
        out["graph_coverage_complete"] = host.graph_coverage_complete;
        out["requested_authority_mask"] = static_cast<int64_t>(
            host.requested_authority_mask);
        out["worker_thread_create_failed"] =
            String(host.fault_code) == String("worker_thread_create_failed");
        // 日等待缺口：今天 worker 卡在哪个域、环境帧是哪一天、环里有几帧。
        out["day_wait_day"] = host.day_wait_day;
        out["day_wait_missing_mask"] = static_cast<int64_t>(host.day_wait_missing_mask);
        out["day_wait_env_day"] = host.day_wait_env_day;
        out["day_wait_ring"] = static_cast<int64_t>(host.day_wait_ring);
        out["environment_ring_pending"] = static_cast<int64_t>(
            host.environment_ring_pending);
        // 预发布领先量：环境帧比已提交日新多少天。K=0（每 day_changed 一帧）时
        // 稳态为 0..1；P1 打开后应稳定在 1..K。
        const int64_t frames_ahead = host.environment_day - host.committed_day;
        out["environment_frames_ahead"] =
            static_cast<int64_t>(frames_ahead > 0 ? frames_ahead : 0);
        out["country_peer_resolved_in_worker"] = static_cast<int64_t>(
            host.country_peer_resolved_in_worker);
        out["country_peer_resolved_by_main"] = static_cast<int64_t>(
            host.country_peer_resolved_by_main);
        out["authoritative_domain_mask"] =
            static_cast<int64_t>(host.authoritative_domain_mask);
        out["active_evidence_mask"] =
            static_cast<int64_t>(host.active_evidence_mask);
        // Same spelling and meaning as `get_runtime_thread_report()`: the perf
        // snapshot must not be the one place that quotes the granted mask alone.
        append_main_thread_suppression(*_runtime_host, host, out);
        out["climate_worker_authoritative"] =
            (host.authoritative_domain_mask &
             runtime_domain_mask(RuntimeDomainId::CLIMATE)) != 0u;
        out["coverage_blocker"] = String(host.coverage_blocker);
        out["simulation_committed_day"] = host.committed_day;
        out["input_capture_count"] = static_cast<int64_t>(host.input_capture_count);
        out["input_capture_reused"] = static_cast<int64_t>(host.input_capture_reused);
        out["economy_input_requested_day"] = _runtime_host->economy_input_requested_day();
        out["simulation_generation"] = static_cast<int64_t>(host.generation);
        out["simulation_state_hash"] = static_cast<int64_t>(host.state_hash);
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
        out["economy_authority_switch_reason"] = String(
            host.economy_authority_switch_reason);
        out["economy_authority_switch_blocker"] = String(
            host.economy_authority_switch_blocker);
        out["economy_authority_switch_audit_before"] = String(
            host.economy_authority_switch_audit_before);
        out["economy_authority_switch_audit_after"] = String(
            host.economy_authority_switch_audit_after);
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
        out["stale_environment_rejected"] = static_cast<int64_t>(host.stale_environment_rejected);
        out["simulation_time_debt_days"] = host.time_debt_days;
        out["time_debt_days"] = host.time_debt_days;
        out["command_queue_capacity_exceeded"] = static_cast<int64_t>(host.command_queue_capacity_exceeded);
        out["receipt_queue_capacity_exceeded"] = static_cast<int64_t>(host.receipt_queue_capacity_exceeded);
        out["day_stage_count"] = static_cast<int>(host.day_stage_count);
        out["day_completed_stage_count"] = static_cast<int>(host.day_completed_stage_count);
        out["day_work_units"] = static_cast<int64_t>(host.day_work_units);
        out["pod_domain_abi_version"] = static_cast<int>(host.pod_domain_abi_version);
        out["pod_completed_domain_mask"] = static_cast<int64_t>(host.pod_completed_domain_mask);
        out["pod_completed_stage_count"] = static_cast<int>(host.pod_completed_stage_count);
        out["pod_work_units"] = static_cast<int64_t>(host.pod_work_units);
        out["pod_intent_count"] = static_cast<int>(host.pod_intent_count);
        out["pod_fallback_count"] = static_cast<int>(host.pod_fallback_count);
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
        // Climate POD is SHADOW-only diagnostic work.  Export it through the
        // graph snapshot so the CSV has the same time series as the host
        // facade, without implying that Climate is an ACTIVE authority.
        out["climate_pod_ready"] = host.climate_pod_ready;
        out["climate_pod_plan_ms"] = host.climate_pod_plan_ms;
        out["climate_pod_replay_ms"] = host.climate_pod_replay_ms;
        out["climate_pod_work_units"] = static_cast<int64_t>(host.climate_pod_work_units);
        out["climate_pod_changed_cells"] = static_cast<int>(host.climate_pod_changed_cells);
        append_climate_stage_cadence(out, host);
        out["climate_pod_state_hash"] = static_cast<int64_t>(host.climate_pod_state_hash);
        out["climate_pod_fallback_reason"] = String(host.climate_pod_fallback_reason);
        out["climate_trace_depth"] = static_cast<int>(host.climate_trace_depth);
        out["climate_trace_front_day"] = host.climate_trace_front_day;
        out["climate_trace_lag_days"] = host.climate_trace_lag_days;
        out["climate_trace_latest_hash"] = static_cast<int64_t>(host.climate_trace_latest_hash);
        out["climate_trace_consumed"] = static_cast<int64_t>(host.climate_trace_consumed);
        out["climate_trace_missing"] = static_cast<int64_t>(host.climate_trace_missing);
    }
    out["day"] = _runtime_graph_day;
    out["generation"] = static_cast<int64_t>(_runtime_graph_generation);
    out["pulse_count"] = static_cast<int64_t>(_runtime_graph_pulse_count);
    out["abi_calls"] = static_cast<int64_t>(_runtime_graph_abi_calls);
    out["gdscript_callbacks"] = static_cast<int64_t>(_runtime_graph_callback_count);
    out["work_done"] = static_cast<int64_t>(_runtime_graph_work_done);
    out["budget_yields"] = static_cast<int64_t>(_runtime_graph_budget_yields);
    out["economy_slices"] = static_cast<int64_t>(_runtime_graph_economy_slices);
    out["economy_commits"] = static_cast<int64_t>(_runtime_graph_economy_commits);
    out["economy_capture_fatal_reason"] =
        String(_runtime_graph_economy_capture_fatal_reason.c_str());
    out["country_peer_adapter_enabled"] =
        _runtime_graph_country_peer_adapter_enabled;
    out["country_peer_service_calls"] = static_cast<int64_t>(
        _runtime_graph_country_peer_service_calls);
    out["country_peer_intents"] = static_cast<int64_t>(
        _runtime_graph_country_peer_intents);
    out["country_peer_completed"] = static_cast<int64_t>(
        _runtime_graph_country_peer_completed);
    out["country_peer_pending_results"] = static_cast<int64_t>(
        _runtime_graph_country_peer_pending);
    out["country_peer_rejected"] = static_cast<int64_t>(
        _runtime_graph_country_peer_rejected);
    out["country_peer_faults"] = static_cast<int64_t>(
        _runtime_graph_country_peer_faults);
    out["country_peer_fault_reason"] = String(
        _runtime_graph_country_peer_fault_reason.c_str());
    out["trigger_blocked_pulses"] =
        static_cast<int64_t>(_runtime_graph_trigger_blocked_pulses);
    out["trigger_blocked_reason"] =
        String(_runtime_graph_trigger_blocked_reason.c_str());
    out["last_elapsed_us"] = static_cast<int64_t>(_runtime_graph_last_elapsed_us);
    out["last_status"] = static_cast<int64_t>(_runtime_graph_last_status);
    out["dirty_mask"] = static_cast<int64_t>(_runtime_graph_dirty_mask);
    out["post_pulse_flush_ms"] = _runtime_graph_post_pulse_flush_ms;
    out["flush_slot_count"] =
        static_cast<int64_t>(_runtime_graph_flush_slot_count);
    out["visual_diff_cell_count"] =
        static_cast<int64_t>(_runtime_graph_visual_diff_cell_count);
    out["country_territory_sync_ms"] =
        _runtime_graph_country_territory_sync_ms;
    out["full_flush_count"] =
        static_cast<int64_t>(_runtime_graph_full_flush_count);
    const NativeParallelExecutor::Report executor =
        NativeParallelExecutor::instance().report();
    out["native_executor_workers"] =
        static_cast<int64_t>(executor.active_worker_limit);
    out["native_executor_interactive"] = executor.interactive;
    out["native_executor_fault_count"] =
        static_cast<int64_t>(executor.fault_count);
    if (detail_level > 0) {
        if (detail_level == 3) append_runtime_golden_report(_runtime_host.get(), out);
        out["next_cursor"] = static_cast<int64_t>(_runtime_graph_next_cursor);
        out["authority"] = String("existing_native_runtimes");
        out["callbacks_in_graph"] = static_cast<int64_t>(_runtime_graph_callback_count);
        const int64_t day = _runtime_graph_day;
        const bool country_worker_owns = _runtime_host != nullptr &&
            (_runtime_host->domain_is_worker_authoritative(RuntimeDomainId::COUNTRY) ||
             _runtime_host->country_authority_owner_is_worker());
        const bool effect_worker_owns = _runtime_host != nullptr &&
            _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::EFFECT);
        const bool modifier_worker_owns = _runtime_host != nullptr &&
            _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::MODIFIER);
        const bool trigger_worker_owns = trigger_worker_authoritative();
        const bool ideology_worker_owns = _runtime_host != nullptr &&
            _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::IDEOLOGY);
        const bool economy_worker_owns = _runtime_host != nullptr &&
            _runtime_host->domain_is_worker_authoritative(RuntimeDomainId::ECONOMY);
        out["country_pending"] = !country_worker_owns && _country_runtime != nullptr &&
            static_cast<NativeCountryRuntime *>(_country_runtime)->should_run(day);
        out["trigger_pending"] = !trigger_worker_owns && _trigger_runtime != nullptr &&
            static_cast<TriggerRuntime *>(_trigger_runtime)->should_run(day);
        out["ideology_pending"] = !ideology_worker_owns && _ideology_runtime != nullptr &&
            static_cast<NativeIdeologyRuntime *>(_ideology_runtime)->should_run(day);
        out["effect_pending"] = !effect_worker_owns && _effect_runtime != nullptr &&
            static_cast<EffectRuntime *>(_effect_runtime)->should_run(day);
        out["modifier_pending"] = !modifier_worker_owns && _modifier_runtime != nullptr &&
            static_cast<ModifierRuntime *>(_modifier_runtime)->should_run(day);
        out["gameplay_effect_pending"] = !effect_worker_owns && _effect_runtime != nullptr &&
            gameplay_effect_should_run(day);
        out["economy_pending"] = !economy_worker_owns && _economy_runtime != nullptr &&
            economy_should_run(day);
        out["gameplay_event_count"] = static_cast<int64_t>(_gameplay_events.size());
        const int64_t *trigger_ack = _gameplay_consumer_ack.getptr(
            StringName("trigger_runtime"));
        out["trigger_event_ack"] = trigger_ack != nullptr ? *trigger_ack : int64_t{0};
    }
    return out;
}

Dictionary DCWorldExt::start_runtime_worker(const Dictionary &config) {
    // Reject before touching executor selection, parallelism or peer bindings.
    if (_runtime_host && (_runtime_host->state() != RuntimeWorkerState::STOPPED ||
                          !_runtime_host->execution_has_stopped())) {
        Dictionary rejected;
        rejected["ok"] = false;
        rejected["pending"] = false;
        rejected["code"] = "runtime_thread_mode_hot_switch_forbidden";
        rejected["thread_report"] = runtime_report_to_dictionary(_runtime_host->report(), _runtime_host.get());
        return rejected;
    }
    if (!_runtime_host) _runtime_host = std::make_unique<NativeSimulationHost>();
    // native_daily_inline：必须在 start() 之前落到 host 上，start() 读它决定
    // "起不起 worker 线程"。缺省 false —— 桌面端路径逐字节不变。
#if defined(__EMSCRIPTEN__)
    // web 上一律走内联日，与有没有 pthreads 无关：
    //  * 无 pthreads（nothreads 包）：std::thread 构造会 abort，必须内联；
    //  * 有 pthreads（threads 包，给 FMOD 用）：host 在 start() 里等 worker
    //    会把浏览器主线程堵死（"Blocking on the main thread is very dangerous"），
    //    实测世界生成走不完；而且同一份 12 域日图 inline 46 ms vs worker 250–370 ms。
    const bool native_daily_inline = true;
#else
    const bool native_daily_inline = static_cast<bool>(
        config.get("native_daily_inline", false));
#endif
    // Inline uses serial dispatch; PK_INLINE_PARALLEL is the diagnostic override.
    static const bool inline_parallel_override = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_INLINE_PARALLEL);
        return value != nullptr && std::strcmp(value, "1") == 0;
    }();
    // [web-parallel 2026-10-31] 浏览器里 Emscripten 的 pthread 池是**固定 16 槽**
    // （导出模板编译期决定，Godot 的 WorkerThreadPool / native daily worker / 音频
    // 已经占掉一部分），而 NativeParallelExecutor 按 `hardware_concurrency()-2`
    // 去 spawn（浏览器报告 8–32 ⇒ 实测要起 8–14 个）。
    //
    // 线程不足时，每一次 `parallel_for_range` 仍要付跨 wasm thread 的
    // 派活 / 唤醒延迟。真机实测（RTX 4080 + Chrome，新 side module）：
    //   worker 模式（并行器开着）：单日墙钟 250–370 ms ⇒ 2.70 天/秒
    //   inline 模式（并行器关着）：单日墙钟 46 ms     ⇒ 9.81 天/秒
    // 同一份 12 域日图、同一台机器，串行比"并行"快 5–8 倍 —— 所以 web 上**一律串行**，
    // 与走 inline 还是 worker 无关。桌面（非 wasm）不受影响。
    // A/B 旁路：PK_WEB_PARALLEL=1 时保留线程池。
    static const bool web_parallel_override = [] {
        const char *value = pk::runtime_switch_value(pk::RuntimeSwitch::PK_WEB_PARALLEL);
        return value != nullptr && std::strcmp(value, "1") == 0;
    }();
#if defined(__EMSCRIPTEN__)
    const bool web_serial_only = !web_parallel_override;
#else
    const bool web_serial_only = false;
#endif
    RuntimeSimulationMode mode = RuntimeSimulationMode::ACTIVE;
    String mode_error;
    Dictionary out;
    if (!parse_runtime_mode(config, mode, mode_error)) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = mode_error;
        out["thread_report"] = runtime_report_to_dictionary(_runtime_host->report(), _runtime_host.get());
        return out;
    }
    const bool complete = static_cast<bool>(config.get("graph_coverage_complete", false));
    const int64_t day = static_cast<int64_t>(config.get("day", 0));
    const double requested_speed = static_cast<double>(config.get("speed_days_per_second", 1.0));
    const double speed = std::isfinite(requested_speed) ? std::max(0.0, requested_speed) : 0.0;
    const bool paused = static_cast<bool>(config.get("paused", false));
    const bool events_probe_enabled = static_cast<bool>(
        config.get("events_probe_enabled", false));
    EconomyExecutionMode economy_execution_mode =
        EconomyExecutionMode::ACTIVE_ONLY;
    bool economy_stage_ops_mutate = true;
    // M6: authority handoff is explicit; this flag is retained only as a
    // compatibility/report field and no longer triggers a worker-side switch.
    bool economy_auto_pod_active = false;
    bool economy_ecp2_dual_write = true;
    bool economy_ecp2_mid_epoch_save = false;
    bool economy_ecp2_authority = false;
    bool economy_stage_ops_soak_experiment = false;
    EconomyProductionWriter economy_production_writer =
        EconomyProductionWriter::STAGE_OPS;
    const bool economy_production_writer_explicit =
        config.has("economy_production_writer");
    if (config.has("economy_stage_ops_mutate")) {
        economy_stage_ops_mutate =
            static_cast<bool>(config.get("economy_stage_ops_mutate", true));
    }
    if (config.has("economy_auto_pod_active")) {
        economy_auto_pod_active =
            static_cast<bool>(config.get("economy_auto_pod_active", false));
    }
    if (config.has("economy_ecp2_dual_write")) {
        economy_ecp2_dual_write =
            static_cast<bool>(config.get("economy_ecp2_dual_write", true));
    }
    if (config.has("economy_ecp2_mid_epoch_save")) {
        economy_ecp2_mid_epoch_save =
            static_cast<bool>(config.get("economy_ecp2_mid_epoch_save", false));
    }
    if (config.has("economy_ecp2_authority")) {
        economy_ecp2_authority =
            static_cast<bool>(config.get("economy_ecp2_authority", false));
    }
    if (config.has("economy_stage_ops_soak_experiment")) {
        economy_stage_ops_soak_experiment = static_cast<bool>(
            config.get("economy_stage_ops_soak_experiment", false));
    }
    if (config.has("economy_production_writer")) {
        const Variant writer_var =
            config.get("economy_production_writer", "compact_slice");
        if (writer_var.get_type() == Variant::INT ||
            writer_var.get_type() == Variant::FLOAT) {
            const int64_t ordinal = static_cast<int64_t>(writer_var);
            if (ordinal < 0 || ordinal > 1) {
                out["ok"] = false;
                out["pending"] = false;
                out["code"] = "runtime_worker_config_invalid";
                out["message"] = "economy_production_writer_out_of_range";
                out["thread_report"] =
                    runtime_report_to_dictionary(_runtime_host->report(), _runtime_host.get());
                return out;
            }
            economy_production_writer =
                static_cast<EconomyProductionWriter>(
                    static_cast<uint32_t>(ordinal));
        } else {
            const String writer_text = String(writer_var);
            CharString utf8 = writer_text.utf8();
            if (!parse_economy_production_writer(utf8.get_data(),
                                                 economy_production_writer)) {
                out["ok"] = false;
                out["pending"] = false;
                out["code"] = "runtime_worker_config_invalid";
                out["message"] = "economy_production_writer_invalid";
                out["thread_report"] =
                    runtime_report_to_dictionary(_runtime_host->report(), _runtime_host.get());
                return out;
            }
        }
    }
    if (config.has("economy_execution_mode")) {
        const Variant mode_var = config.get("economy_execution_mode", "ACTIVE_ONLY");
        if (mode_var.get_type() == Variant::INT ||
            mode_var.get_type() == Variant::FLOAT) {
            const int64_t ordinal = static_cast<int64_t>(mode_var);
            if (ordinal < 0 || ordinal > 2) {
                out["ok"] = false;
                out["pending"] = false;
                out["code"] = "runtime_worker_config_invalid";
                out["message"] = "economy_execution_mode_out_of_range";
                out["thread_report"] =
                    runtime_report_to_dictionary(_runtime_host->report(), _runtime_host.get());
                return out;
            }
            economy_execution_mode =
                static_cast<EconomyExecutionMode>(static_cast<uint32_t>(ordinal));
        } else {
            const String mode_text = String(mode_var);
            CharString utf8 = mode_text.utf8();
            if (!parse_economy_execution_mode(utf8.get_data(),
                                              economy_execution_mode)) {
                out["ok"] = false;
                out["pending"] = false;
                out["code"] = "runtime_worker_config_invalid";
                out["message"] = "economy_execution_mode_invalid";
                out["thread_report"] =
                    runtime_report_to_dictionary(_runtime_host->report(), _runtime_host.get());
                return out;
            }
        }
    }
    if (day < 0 || !std::isfinite(requested_speed)) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "runtime_worker_config_invalid";
        out["thread_report"] = runtime_report_to_dictionary(_runtime_host->report(), _runtime_host.get());
        return out;
    }
    if (native_daily_inline && mode == RuntimeSimulationMode::SHADOW) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "runtime_worker_config_invalid";
        out["message"] = "inline_daily_requires_active";
        return out;
    }
    // per-domain 权威：调用方点名它要 worker 拥有哪些域，缺省才是整图。
    //
    // 准入门必须跟着这个掩码走，而不是恒查 implemented_domain_mask ==
    // RUNTIME_ALL_DOMAIN_MASK —— 那条整图门意味着 Climate 要等全部 12 个域都有 POD
    // handler 才能转 ACTIVE，而 Climate 自己早就齐了。掩码里没点到的域仍在主线程，
    // 它们有没有 handler 与这次授权无关。
    //
    // COMMIT 是 barrier 域本身，host 侧也会补上；这里一并纳入判定，否则调用方只写
    // CLIMATE 时会被自己没请求的域挡下。
    const uint32_t all_mask = static_cast<uint32_t>(RUNTIME_ALL_DOMAIN_MASK);
    uint32_t requested_authority_mask = all_mask;
    if (config.has("authoritative_domain_mask")) {
        const Variant raw = config["authoritative_domain_mask"];
        if (raw.get_type() != Variant::INT) {
            out["ok"] = false;
            out["pending"] = false;
            out["code"] = "runtime_worker_config_invalid";
            out["message"] = "authoritative_domain_mask_not_int";
            out["thread_report"] = runtime_report_to_dictionary(_runtime_host->report(), _runtime_host.get());
            return out;
        }
        const int64_t value = static_cast<int64_t>(raw);
        if (value <= 0 || (static_cast<uint32_t>(value) & ~all_mask) != 0u) {
            out["ok"] = false;
            out["pending"] = false;
            out["code"] = "runtime_worker_config_invalid";
            out["message"] = "authoritative_domain_mask_out_of_range";
            out["thread_report"] = runtime_report_to_dictionary(_runtime_host->report(), _runtime_host.get());
            return out;
        }
        requested_authority_mask =
            static_cast<uint32_t>(value) |
            runtime_domain_mask(RuntimeDomainId::COMMIT);
    }
    const uint32_t missing_requested =
        requested_authority_mask &
        ~static_cast<uint32_t>(NativeSimulationHost::implemented_domain_mask());
    if (mode == RuntimeSimulationMode::ACTIVE &&
        (!complete || missing_requested != 0u)) {
        out["ok"] = false;
        out["pending"] = false;
        const bool domains_missing = complete && missing_requested != 0u;
        out["code"] = domains_missing
            ? "runtime_native_domains_incomplete"
            : "runtime_graph_not_thread_safe";
        out["message"] = domains_missing
            ? "native_domain_pod_handlers_incomplete"
            : "runtime_graph_contains_godot_bridge";
        out["requested_authority_mask"] =
            static_cast<int64_t>(requested_authority_mask);
        out["missing_domain_mask"] = static_cast<int64_t>(missing_requested);
        out["completion_gate_missing_domain_mask"] =
            static_cast<int64_t>(missing_requested);
        out["active_gate_blocked"] = true;
        out["thread_report"] = runtime_report_to_dictionary(_runtime_host->report(), _runtime_host.get());
        return out;
    }
    if (economy_execution_mode == EconomyExecutionMode::LEGACY_ONLY) {
        // Keep sync ECONOMY_GRAPH as the sole writer; do not grant worker ECONOMY.
        requested_authority_mask &=
            ~runtime_domain_mask(RuntimeDomainId::ECONOMY);
        requested_authority_mask |=
            runtime_domain_mask(RuntimeDomainId::COMMIT);
    }
    // ACTIVE_WITH_PARITY needs compact production + read-only SHADOW StageOps.
    // Default writer is stage_ops; coerce unless the caller explicitly asked
    // for stage_ops (that remains a hard conflict).
    if (economy_execution_mode == EconomyExecutionMode::ACTIVE_WITH_PARITY) {
        economy_stage_ops_mutate = false;
        if (economy_production_writer == EconomyProductionWriter::STAGE_OPS &&
            !economy_production_writer_explicit) {
            economy_production_writer =
                EconomyProductionWriter::COMPACT_SLICE;
        }
    }
    // Phase-2.4.2 fail-closed gates for STAGE_OPS production writer.
    if (economy_production_writer == EconomyProductionWriter::STAGE_OPS) {
        if (economy_execution_mode ==
            EconomyExecutionMode::ACTIVE_WITH_PARITY) {
            out["ok"] = false;
            out["pending"] = false;
            out["code"] = "runtime_worker_config_invalid";
            out["message"] = "economy_production_writer_parity_conflict";
            out["thread_report"] =
                runtime_report_to_dictionary(_runtime_host->report(), _runtime_host.get());
            return out;
        }
        if (!economy_stage_ops_mutate) {
            out["ok"] = false;
            out["pending"] = false;
            out["code"] = "runtime_worker_config_invalid";
            out["message"] = "economy_production_writer_requires_mutate";
            out["thread_report"] =
                runtime_report_to_dictionary(_runtime_host->report(), _runtime_host.get());
            return out;
        }
        // Phase-2.4.5: StageOps writer is production-ready after dual-path soak
        // handoff. Keep parity / mutate fail-closed gates above.
        const uint32_t readiness = ECONOMY_STAGE_OPS_READY_PRELUDE |
                                   ECONOMY_STAGE_OPS_READY_COMMIT_DRAINS |
                                   ECONOMY_STAGE_OPS_READY_BOUNDED_KERNELS |
                                   ECONOMY_STAGE_OPS_READY_HOST_LOOP;
        const uint32_t missing =
            ECONOMY_STAGE_OPS_READY_REQUIRED_FOR_WRITER & ~readiness;
        if (missing != 0u) {
            out["ok"] = false;
            out["pending"] = false;
            out["code"] = "runtime_worker_config_invalid";
            out["message"] = "economy_production_writer_stage_ops_not_ready";
            out["economy_stage_ops_readiness_mask"] =
                static_cast<int64_t>(readiness);
            out["economy_stage_ops_readiness_missing"] =
                static_cast<int64_t>(missing);
            out["thread_report"] =
                runtime_report_to_dictionary(_runtime_host->report(), _runtime_host.get());
            return out;
        }
    }
    _runtime_display_commit = {};
    _runtime_display_resources.reset();
    _climate_physics_committed.reset();
    _climate_writeback_applied_generation = 0;
    _climate_writeback_applied_day = -1;
    _runtime_host->set_inline_daily_mode(native_daily_inline);
    set_parallel_serial_only(
        (native_daily_inline && !inline_parallel_override) || web_serial_only);
    if (_country_runtime != nullptr) {
        static_cast<NativeCountryRuntime *>(_country_runtime)
            ->attach_simulation_host(_runtime_host.get());
    }
    attach_country_ai_to_host();
    _runtime_host->set_events_probe_enabled(events_probe_enabled);
    _runtime_host->set_economy_execution_mode(economy_execution_mode);
    _runtime_host->set_economy_stage_ops_soak_experiment(
        economy_stage_ops_soak_experiment);
    _runtime_host->set_economy_production_writer(economy_production_writer);
    _runtime_host->set_economy_stage_ops_mutate(economy_stage_ops_mutate);
    _runtime_host->set_economy_auto_pod_active(economy_auto_pod_active);
    _runtime_host->set_economy_ecp2_dual_write(economy_ecp2_dual_write);
    _runtime_host->set_economy_ecp2_mid_epoch_save(economy_ecp2_mid_epoch_save);
    _runtime_host->set_economy_ecp2_authority(economy_ecp2_authority);
    if (_economy_runtime != nullptr) {
        auto *economy =
            static_cast<NativeEconomyRuntime *>(_economy_runtime);
        economy->attach_simulation_host(_runtime_host.get());
        // Phase-2.4.5: StageOps mutate is the default production writer.
        // ACTIVE_WITH_PARITY keeps StageOps read-only so the SHADOW probe
        // cannot double-write beside worker_run_compact_slice.
        _runtime_host->attach_economy_stage_ops(
            economy->make_graph_stage_ops(/*mutate=*/economy_stage_ops_mutate));
        auto *main_modifier = static_cast<ModifierRuntime *>(_modifier_runtime);
        // start() has not granted authority yet on a cold world. Select the
        // consumer from the validated upcoming configuration, not the previous
        // lifetime's grant: otherwise Economy keeps reading the main-thread
        // copy and its first post-load production sees stale Country factors.
        const uint32_t economy_modifier_mask =
            runtime_domain_mask(RuntimeDomainId::ECONOMY) |
            runtime_domain_mask(RuntimeDomainId::MODIFIER);
        const bool use_economy_modifier_view =
            mode == RuntimeSimulationMode::ACTIVE && main_modifier != nullptr &&
            (requested_authority_mask & economy_modifier_mask) == economy_modifier_mask;
        if (use_economy_modifier_view) {
            // The worker economy must not read the main-thread ModifierRuntime:
            // the main thread rebuilds it from worker snapshots at its own
            // pace, so a day could see a stale generation (resume diverged on
            // exactly that). Start from the main copy -- after configure or
            // restore it holds the building identities -- and let the modifier
            // stage refresh it. A restart of the same world keeps the view: its
            // identities are the ones the economy rows already reference.
            auto *view = static_cast<ModifierRuntime *>(_economy_modifier_view);
            if (view == nullptr) {
                view = modifier_api::copy_runtime(*main_modifier).release();
                _economy_modifier_view = view;
            } else if (!_economy_modifier_view_attached) {
                modifier_api::replace_runtime(
                    *view, std::move(*modifier_api::copy_runtime(*main_modifier)));
            }
            modifier_api::reset_pod_snapshot_generation(*view);
            economy->attach_modifier_runtime(view);
            _runtime_host->attach_economy_modifier_view(view);
        } else {
            economy->attach_modifier_runtime(main_modifier);
            _runtime_host->attach_economy_modifier_view(nullptr);
        }
        _economy_modifier_view_attached = use_economy_modifier_view;
        if (economy_execution_mode != EconomyExecutionMode::LEGACY_ONLY) {
            if (mode == RuntimeSimulationMode::ACTIVE &&
                (requested_authority_mask & runtime_domain_mask(RuntimeDomainId::ECONOMY)) != 0u &&
                economy->worker_natural_resources_configured() &&
                !seed_runtime_resource_reserves(*economy, day)) {
                out["ok"] = false;
                out["code"] = "resource_start_seed_invalid";
                return out;
            }
            if (mode == RuntimeSimulationMode::ACTIVE &&
                requested_authority_mask == RUNTIME_ALL_DOMAIN_MASK &&
                !seed_runtime_bio(*economy)) {
                out["ok"] = false;
                out["code"] = "bio_start_seed_invalid";
                return out;
            }
            _runtime_host->attach_economy_production_runtime(economy);
        } else {
            _runtime_host->attach_economy_production_runtime(nullptr);
        }
    }
    if (_military && mode == RuntimeSimulationMode::ACTIVE &&
            requested_authority_mask == RUNTIME_ALL_DOMAIN_MASK) {
        if (!_runtime_host->has_started_once())
            _runtime_host->seed_events_ingress_cursor(_gameplay_next_event_id);
        bind_military_dependencies();
        _runtime_host->attach_military(_military);
    } else {
        _runtime_host->attach_military(nullptr);
    }
    const bool owns_rule_adapters = mode == RuntimeSimulationMode::ACTIVE &&
        requested_authority_mask == RUNTIME_ALL_DOMAIN_MASK;
    if (_ideology_runtime != nullptr) {
        auto *ideology = static_cast<NativeIdeologyRuntime *>(_ideology_runtime);
        ideology->reset_pod_snapshot_cursor();
        ideology->attach_modifier_runtime(static_cast<ModifierRuntime *>(_modifier_runtime));
    }
    _runtime_host->attach_effect_adapter(
        owns_rule_adapters ? static_cast<EffectRuntime *>(_effect_runtime) : nullptr,
        owns_rule_adapters ? static_cast<NativeCountryRuntime *>(_country_runtime) : nullptr,
        owns_rule_adapters ? static_cast<TriggerRuntime *>(_trigger_runtime) : nullptr,
        owns_rule_adapters ? static_cast<NativeIdeologyRuntime *>(_ideology_runtime) : nullptr);
    if (!_runtime_host->start(mode, complete, day, speed, paused,
                              requested_authority_mask)) {
        out["ok"] = false;
        out["pending"] = false;
        out["code"] = "runtime_worker_start_failed";
        out["thread_report"] = runtime_report_to_dictionary(_runtime_host->report(), _runtime_host.get());
        return out;
    }
    // A DCWorldExt instance may be reused for a second world after the prior
    // worker has stopped.  Do not let the new run expose the previous world's
    // commit or visual intents through the main-thread cache.
    // A restore start is granted immediately; make the main-thread peers see
    // that grant now rather than on a runtime-graph pulse that may not run.
    sync_runtime_domain_ownership();
    apply_runtime_economy_resource_writeback();
    out["ok"] = true;
    out["pending"] = mode != RuntimeSimulationMode::OFF;
    out["code"] = "ok";
    out["requested_simulation_thread_mode"] = runtime_mode_name(mode);
    out["economy_execution_mode"] =
        String(economy_execution_mode_name(economy_execution_mode));
    out["economy_stage_ops_mutate"] = economy_stage_ops_mutate;
    out["economy_auto_pod_active"] = economy_auto_pod_active;
    out["economy_stage_ops_soak_experiment"] =
        economy_stage_ops_soak_experiment;
    out["economy_stage_ops_soak_parity_ok"] =
        _runtime_host->economy_stage_ops_soak_parity_ok();
    out["economy_production_writer"] = String(
        economy_production_writer_name(
            _runtime_host->economy_production_writer_requested()));
    out["economy_production_writer_requested"] = String(
        economy_production_writer_name(
            _runtime_host->economy_production_writer_requested()));
    out["economy_production_writer_effective"] = String(
        economy_production_writer_name(
            _runtime_host->economy_production_writer_effective()));
    out["state"] = runtime_state_name(_runtime_host->state());
    // The two mask ledgers, at the moment this lifetime starts. A FRESH start
    // reports requested != 0 with granted == 0 (deferred until the first commit);
    // a RESTART additionally reports the per-host ledger it just re-published, so a
    // caller can tell "the grant carried over" from "the grant is still pending"
    // without waiting for a day to commit.
    //
    // ONE report construction for all of it: `report()` builds timers, queues and
    // domain snapshots, and this reply used to build three of them.
    const RuntimeThreadReport start_report = _runtime_host->report();
    out["requested_authority_mask"] =
        static_cast<int64_t>(start_report.requested_authority_mask);
    out["authoritative_domain_mask"] =
        static_cast<int64_t>(_runtime_host->authoritative_domain_mask());
    // A FRESH start is exactly where the trap opens: the domains in the request are
    // already suppressed on the main thread (`domain_main_thread_suppressed`) while
    // `authoritative_domain_mask` is still 0, so a caller reading only the grant
    // cannot tell "not granted yet" from "not mine to run". Report both masks here.
    append_main_thread_suppression(*_runtime_host, start_report, out);
    out["lifetime_granted_mask"] =
        static_cast<int64_t>(_runtime_host->lifetime_granted_mask());
    out["native_daily_inline"] = native_daily_inline;
    out["thread_report"] =
        runtime_report_to_dictionary(start_report, _runtime_host.get());
    return out;
}

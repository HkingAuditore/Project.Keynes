Dictionary DCWorldExt::run_native_daily_inline_day() {
    Dictionary out;
    if (!_runtime_host) {
        out["ok"] = false;
        out["code"] = "runtime_host_missing";
        out["reason"] = "runtime_host_missing";
        return out;
    }
    if (!_runtime_host->inline_daily_mode()) {
        out["ok"] = false;
        out["code"] = "native_daily_inline_disabled";
        out["reason"] = "native_daily_inline_disabled";
        return out;
    }
    const auto started = std::chrono::steady_clock::now();
    // 一天之内最多重试这么多次。Country 的 peer 集合是"每天有限个 intent"，
    // 一轮泵就完成一批，所以这个上限只防退化，不是性能旋钮。
    constexpr uint32_t kMaxInlineAttempts = 8u;
    constexpr int kPeerIntentsPerPump = 256;
    // 整次调用的墙钟总预算。单次尝试另有 execute_day_plan 里的 stage 间看门狗，
    // 这一道总闸保证"8 次重试 × 每次接近预算"也不会把主线程钉住 —— 浏览器里
    // 一次可上报的失败远好过页面再无心跳。
    const int64_t total_budget_us = NativeSimulationHost::inline_day_budget_us();
    const auto elapsed_us = [&started]() -> int64_t {
        return std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - started).count();
    };
    const auto ms_since = [](std::chrono::steady_clock::time_point mark) -> double {
        return std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - mark).count();
    };
    NativeSimulationHost::InlineDayOutcome outcome;
    uint32_t attempts = 0;
    uint64_t peer_pumped = 0;
    // 分域耗时按"尝试"求和：一次内联日可能重试同一天，重试会把 Climate/Country
    // 再付一次，所以 stage_ms 是真正烧掉的 CPU，attempt_ms 是每次尝试的总账。
    double stage_ms[RUNTIME_DOMAIN_STAGE_COUNT]{};
    double pre_stage_ms = 0.0;
    double climate_ms = 0.0;
    double plan_build_ms = 0.0;
    double commit_tail_ms = 0.0;
    double peer_ms = 0.0;
    bool budget_exceeded = false;
    // 区分两种掐断：单日看门狗（execute_day_plan 里按 stage 间检查）与本次
    // 调用的总预算（8 次重试加起来）。前者 reason 已由 host 写好，后者要在
    // 这里盖一个自己的原因码，否则浏览器只会看到上一次尝试的 peer 原因。
    bool attempt_budget_tripped = false;
    Array attempt_ms;
    while (attempts < kMaxInlineAttempts) {
        ++attempts;
        const auto attempt_started = std::chrono::steady_clock::now();
        outcome = _runtime_host->run_inline_day();
        attempt_ms.append(ms_since(attempt_started));
        for (uint32_t i = 0; i < RUNTIME_DOMAIN_STAGE_COUNT; ++i)
            stage_ms[i] += outcome.stage_ms[i];
        pre_stage_ms += outcome.pre_stage_ms;
        climate_ms += outcome.climate_ms;
        plan_build_ms += outcome.plan_build_ms;
        commit_tail_ms += outcome.commit_tail_ms;
        if (outcome.budget_exceeded) {
            budget_exceeded = true;
            break;
        }
        if (outcome.committed || !outcome.continuation_pending) break;
        if (total_budget_us > 0 && elapsed_us() >= total_budget_us) {
            budget_exceeded = true;
            attempt_budget_tripped = true;
            break;
        }
        // A later stage can acknowledge Country's requests during this
        // attempt. The next Country stage can consume those results directly.
        if (outcome.country_peer_progress) continue;
        // peer 就在本线程。把 Country peer 适配器推一轮（Effect/Modifier/
        // Economy 的 intent 服务都由它同一线程完成），再重试同一天。
        if (_country_runtime == nullptr) break;
        auto *country = static_cast<NativeCountryRuntime *>(_country_runtime);
        if (!country->peer_async_mode()) country->set_peer_async_mode(true);
        NativeCountryRuntime::PeerAdapterServiceReport peer_report;
        std::string peer_error;
        const auto peer_started = std::chrono::steady_clock::now();
        const bool peer_ok = country->service_peer_intents_main_thread(
            kPeerIntentsPerPump, peer_report, peer_error);
        peer_ms += ms_since(peer_started);
        if (!peer_ok) {
            out["peer_error"] = String(peer_error.empty()
                ? "country_peer_adapter_service_failed" : peer_error.c_str());
            break;
        }
        peer_pumped += peer_report.inspected;
        // 一轮泵什么都没看到，说明卡的不是 peer（例如输入帧/经济输入），
        // 再试同一天只会原样失败。
        if (peer_report.inspected == 0u) break;
    }
    // Inline earns its first grants inside the call. Deliver them before the
    // main-thread save/should_run gates can advance a stale sync facade.
    sync_runtime_domain_ownership();
    const double elapsed_ms = ms_since(started);
    const RuntimeThreadReport report = _runtime_host->report();
    out["ok"] = outcome.committed;
    out["code"] = outcome.committed ? "ok"
        : (attempt_budget_tripped ? String("inline_daily_attempt_budget_exceeded")
                                  : String(outcome.reason));
    out["reason"] = attempt_budget_tripped && !outcome.committed
        ? String("inline_daily_attempt_budget_exceeded")
        : String(outcome.reason);
    out["attempts"] = static_cast<int>(attempts);
    out["peer_pumped"] = static_cast<int64_t>(peer_pumped);
    out["from_day"] = outcome.from_day;
    out["day"] = outcome.day;
    out["environment_day"] = outcome.environment_day;
    out["committed_day"] = report.committed_day;
    out["completed_domain_mask"] =
        static_cast<int64_t>(outcome.completed_domain_mask);
    out["completed_stage_count"] = static_cast<int>(outcome.completed_stage_count);
    out["stage_count"] = static_cast<int>(outcome.stage_count);
    out["work_units"] = static_cast<int64_t>(outcome.work_units);
    out["dirty_families"] = static_cast<int64_t>(outcome.dirty_families);
    out["preflight_ok"] = outcome.committed;
    out["continuation_pending"] = outcome.continuation_pending;
    out["elapsed_ms"] = elapsed_ms;
    // ===== 分域/分阶段耗时（新键，既有键语义完全不变）=====
    //
    // stage_ms：12 域各自累加的毫秒数（键名见 runtime_domain_stage_key）。
    //   stage_ms["climate"] 是 Climate 内核的真实耗时 —— 内核在 12 域循环之前
    //   就跑完，所以它同时是 pre_stage_ms 的一部分。
    // attempt_ms：每次尝试的总毫秒（重试会把同一域再付一次）。
    // peer_ms：Country peer 泵的总毫秒（重试之间在调用线程上跑）。
    // plan_build_ms / commit_tail_ms：build_day_plan / 日尾发布各自的毫秒。
    // budget_exceeded：是否被单日墙钟看门狗掐断（此时 ok=false）。
    // executor_serial_only：本线程是否已把 pk::parallel_for_range 的固定线程池
    //   切成串行（内联日必须为 true，否则浏览器主线程会等一组 wasm pthread）。
    {
        Dictionary stage_dict;
        constexpr auto order = runtime_domain_stage_order();
        for (uint32_t i = 0; i < RUNTIME_DOMAIN_STAGE_COUNT; ++i)
            stage_dict[runtime_domain_stage_key(order[i])] = stage_ms[i];
        out["stage_ms"] = stage_dict;
    }
    out["attempt_ms"] = attempt_ms;
    out["pre_stage_ms"] = pre_stage_ms;
    out["climate_ms"] = climate_ms;
    out["plan_build_ms"] = plan_build_ms;
    out["commit_tail_ms"] = commit_tail_ms;
    out["peer_ms"] = peer_ms;
    // capture_ms：紧接本次调用之前的 capture_runtime_inputs() 花了多少毫秒。
    // 调用方那一帧 = capture_ms + elapsed_ms + 其余 GDScript；三者一比就能
    // 判定浏览器里那 24 秒到底在 C++ 日屏障里还是在捕获/应用侧。
    out["capture_ms"] = _inline_capture_ms;
    out["budget_exceeded"] = budget_exceeded;
    out["budget_ms"] = total_budget_us > 0
        ? static_cast<double>(total_budget_us) / 1000.0 : 0.0;
    out["executor_serial_only"] = parallel_serial_only();
    // 执行器账目：内联日必须"一次真并行 group 都不派"。调用方拿两个累计量的
    // 差值就能验证 —— dispatch 只涨 serial_dispatch 时，浏览器主线程这一帧
    // 从头到尾没碰过 wasm pthread，也就不会在 group barrier 上等一个起不来的
    // worker。
    {
        const NativeParallelExecutor::Report executor =
            NativeParallelExecutor::instance().report();
        out["executor_workers"] = static_cast<int>(executor.worker_threads);
        out["executor_dispatch"] =
            static_cast<int64_t>(executor.dispatch_count);
        out["executor_serial_dispatch"] =
            static_cast<int64_t>(executor.serial_dispatch_count);
        out["executor_tasks"] = static_cast<int64_t>(executor.task_count);
    }
    out["inline_daily"] = true;
    out["simulation_thread_mode"] = runtime_mode_name(report.mode);
    out["simulation_host_state"] = runtime_state_name(report.state);
    out["authoritative_domain_mask"] =
        static_cast<int64_t>(report.authoritative_domain_mask);
    return out;
}

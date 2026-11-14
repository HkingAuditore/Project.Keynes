#include "native_simulation_day_context.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "pk_log.h"
#include <algorithm>
#include <chrono>

namespace pk {
RuntimeDayCommit NativeSimulationHost::execute_shadow_day(DayExecution &day) {
    auto &plan = day.plan;
    auto &environment = day.environment;
    auto &day_commands = day.day_commands;
    auto &admitted_submit_order = day.admitted_submit_order;
    auto &commit = day.commit;

    const auto country_snapshot = std::atomic_load_explicit(
        &_country_snapshot, std::memory_order_acquire);
    RuntimeClimateVerticalReport climate_report;
    bool climate_ok = false;
    RuntimeClimateReferenceFrame trace_frame;
    const RuntimeClimateTracePopResult trace_result =
        _climate_trace.pop_for_day(plan.context.day, trace_frame);
    if (trace_result == RuntimeClimateTracePopResult::CONSUMED) {
        _climate_trace_consumed.fetch_add(1, std::memory_order_relaxed);
        _climate_trace_latest_hash.store(trace_frame.trace_hash,
                                         std::memory_order_release);
    } else {
        _climate_trace_missing.fetch_add(1, std::memory_order_relaxed);
    }
    // A SHADOW Climate day is valid only when the OFF reference has
    // released the matching trace frame. Never silently substitute the
    // latest live environment: doing so would make parity non-replayable.
    const RuntimeEnvironmentSnapshot *climate_environment =
        trace_result == RuntimeClimateTracePopResult::CONSUMED &&
            trace_frame.environment != nullptr
            ? trace_frame.environment.get() : nullptr;
    // Climate 日以 trace/environment 为准，不是 plan.context.day。
    // 后者是 worker 时钟 `_committed_day + 1`；第一帧常见情况是生成期
    // environment.day=0，而 worker 已经在计划 day=1。ACTIVE 路径已经按
    // environment.day 对齐；SHADOW 冷启动若把 store.committed_day 写成计划日，
    // 下一帧真正的 plan_day 会撞上 climate_day_not_monotonic，Climate barrier
    // 永久失败，Country 对拍永远进不去。
    const int64_t climate_day = climate_environment != nullptr
        ? climate_environment->day : -1;
    // 冷启动引导：worker 的 store 是全零，而它拿到的第一帧 reference 已经带着
    // 整个世界生成期的 Climate 结果。这一天比的不是算法，而是"worker 没见过
    // 世界生成"，必然红，且红在每一个字段上——把它当对拍数据会污染整张分叉矩阵。
    //
    // 所以第一帧只做一件事：把生产状态整体收作 worker 的起点，不计入对拍。
    // 之后每一天 worker 才真的从与生产同一个基线往前推。
    const bool climate_cold_start =
        climate_environment != nullptr &&
        _climate_authority.store().committed_day < 0 &&
        trace_frame.reference_store != nullptr;
    // S3 冷启动边界诊断：cold start 落在哪一天、采纳的 reference 是哪个哈希，
    // 以及紧随其后的几天 worker 究竟跑了哪些 stage。day 2 的一次性分叉只可能
    // 出在这两者之一，靠分叉矩阵反推不出来。
    static std::atomic<int> s_climate_boundary_reports_left{8};
    if (climate_cold_start) {
        std::memset(&climate_report, 0, sizeof(climate_report));
        if (_climate_authority.adopt_reference_baseline(
                climate_day, *trace_frame.reference_store,
                *climate_environment, climate_report)) {
            runtime_copy_text(climate_report.parity_reason,
                              "climate_cold_start_baseline");
            // 日对齐时，这一天的生产态就是基线，可以放行 worker 日。
            // 日错位时只收基线、不放行：让下一轮再吃匹配帧，避免跳过该日的
            // Climate 对拍，也避免 Country 在 Climate 还没算到计划日时前进。
            climate_ok = (climate_day == plan.context.day);
        } else {
            if (climate_report.error[0] == '\0') {
                runtime_copy_text(climate_report.error,
                                  "climate_cold_start_baseline_failed");
            }
            climate_ok = false;
        }
        if (s_climate_boundary_reports_left.fetch_sub(1, std::memory_order_relaxed) > 0) {
            std::fprintf(stderr,
                         "[climate][boundary] cold-start env_day=%lld plan_day=%lld "
                         "ok=%d ref_hash=%llu adopted_parity=%llu round_ran=%d\n",
                         static_cast<long long>(climate_day),
                         static_cast<long long>(plan.context.day), climate_ok ? 1 : 0,
                         static_cast<unsigned long long>(trace_frame.reference_state_hash),
                         static_cast<unsigned long long>(
                             _climate_authority.store().parity_hash()),
                         climate_environment->climate_round_ran ? 1 : 0);
            std::fflush(stderr);
        }
        _climate_pod_parity_compared.store(false, std::memory_order_release);
        _climate_pod_parity_matched.store(false, std::memory_order_release);
        _climate_parity_day.store(climate_day, std::memory_order_release);
        for (size_t i = 0; i < _climate_pod_parity_reason.size(); ++i) {
            _climate_pod_parity_reason[i].store(
                climate_report.parity_reason[i], std::memory_order_release);
            if (climate_report.parity_reason[i] == '\0') break;
        }
    } else if (climate_environment != nullptr) {
        if (climate_day != plan.context.day) {
            std::memset(&climate_report, 0, sizeof(climate_report));
            runtime_copy_text(climate_report.error,
                              "climate_environment_day_mismatch");
            climate_ok = false;
            if (s_climate_boundary_reports_left.fetch_sub(1, std::memory_order_relaxed) > 0) {
                std::fprintf(stderr,
                             "[climate][boundary] day=%lld env_day=%lld planned=0 "
                             "compared=0 matched=0 err=climate_environment_day_mismatch\n",
                             static_cast<long long>(plan.context.day),
                             static_cast<long long>(climate_day));
                std::fflush(stderr);
            }
        } else {
        const bool climate_planned = _climate_authority.plan_day(
            climate_day, *climate_environment, climate_report,
            /*compute_hashes=*/true, /*validate_input=*/false);
        // plan_day resets the report, so attach the trace metadata only
        // after the authority has filled its execution diagnostics.
        climate_report.reference_state_hash = trace_frame.reference_state_hash;
        climate_report.parity_compared = climate_planned &&
            trace_frame.reference_state_hash != 0;
        // Compare the canonical parity reduction, not state_hash. The
        // latter mixes in worker-only bookkeeping (generation, rng_state,
        // history cursor) that no production reference can reproduce, so
        // comparing it could never succeed.
        climate_report.parity_matched = climate_report.parity_compared &&
            climate_report.parity_hash == trace_frame.reference_state_hash;
        if (s_climate_boundary_reports_left.fetch_sub(1, std::memory_order_relaxed) > 0) {
            std::fprintf(stderr,
                         "[climate][boundary] day=%lld planned=%d compared=%d matched=%d "
                         "worker_parity=%llu ref=%llu stage_ran=0x%X prod_stage=0x%X "
                         "round_ran=%d alb=%d veg=%d fb=%d err=%s\n",
                         static_cast<long long>(climate_day), climate_planned ? 1 : 0,
                         climate_report.parity_compared ? 1 : 0,
                         climate_report.parity_matched ? 1 : 0,
                         static_cast<unsigned long long>(climate_report.parity_hash),
                         static_cast<unsigned long long>(trace_frame.reference_state_hash),
                         climate_report.worker_stage_mask,
                         climate_report.production_stage_mask,
                         climate_environment->climate_round_ran ? 1 : 0,
                         climate_environment->climate_albedo.ran ? 1 : 0,
                         climate_environment->climate_vegetation != nullptr &&
                             climate_environment->climate_vegetation->knobs.ran ? 1 : 0,
                         climate_environment->climate_feedback != nullptr &&
                             climate_environment->climate_feedback->knobs.ran ? 1 : 0,
                         climate_report.error);
            std::fflush(stderr);
        }
        if (!climate_planned) {
            // Preserve the authority's first execution/preflight error;
            // a failed plan is not a parity comparison and must not be
            // relabeled as a hash mismatch.
            climate_report.parity_reason[0] = '\0';
            if (climate_report.error[0] == '\0') {
                runtime_copy_text(climate_report.error,
                                  "climate_execution_failed");
            }
            climate_ok = false;
        } else if (!climate_report.parity_compared) {
            // The trace ring normally refuses to expose a frame before
            // a non-zero reference hash is recorded. Treat a malformed
            // or incomplete frame as a hard input barrier anyway; never
            // let a non-compared day look ready.
            climate_report.parity_reason[0] = '\0';
            _climate_authority.discard_plan();
            climate_report.completed = 0;
            climate_ok = false;
            climate_report.preflight_ok = 0;
            runtime_copy_text(climate_report.error,
                              "climate_reference_hash_missing");
        } else if (!climate_report.parity_matched) {
            // Two unequal hashes say nothing about which stage diverged.
            // When the frame carries the production state, locate the
            // first differing field and cell; that is what turns a red
            // light into a work item.
            if (trace_frame.reference_store != nullptr) {
                RuntimeClimateParityReport diff;
                diff.day = climate_day;
                // The full per-field fold is what the divergence matrix is
                // built from; the first difference alone would only ever
                // name the earliest field in table order.
                accumulate_climate_parity_fields(
                    climate_day, *trace_frame.reference_store,
                    _climate_authority.planned_store());
                if (runtime_climate_parity_first_difference(
                        *trace_frame.reference_store,
                        _climate_authority.planned_store(), diff)) {
                    const RuntimeClimateParityField *field =
                        runtime_climate_parity_field(diff.field);
                    if (field != nullptr) {
                        diff.stage = static_cast<uint16_t>(field->stage);
                    }
                    publish_climate_parity_divergence(diff);
                    if (s_climate_boundary_reports_left.load(std::memory_order_relaxed) > -8) {
                        std::fprintf(stderr,
                                     "[climate][boundary] day=%lld first_diff=%s[%u] "
                                     "ref=%s worker=%s\n",
                                     static_cast<long long>(climate_day), diff.field,
                                     diff.cell, diff.reference_bits, diff.worker_bits);
                        std::fflush(stderr);
                    }
                    runtime_copy_text(climate_report.parity_reason,
                                      "climate_reference_field_mismatch");
                } else {
                    // The fields agree but the hashes do not, which means
                    // the two sides disagree about the framing rather than
                    // about the physics.
                    clear_climate_parity_divergence();
                    runtime_copy_text(climate_report.parity_reason,
                                      "climate_reference_framing_mismatch");
                }
            } else {
                clear_climate_parity_divergence();
                runtime_copy_text(climate_report.parity_reason,
                                  "climate_reference_hash_mismatch");
            }
            if (_climate_parity_forcing.load(std::memory_order_acquire) &&
                trace_frame.reference_store != nullptr) {
                // Measurement mode. Retrying the same day forever would
                // pin the whole run to its first divergence, so adopt the
                // production state and let the next day be measured on its
                // own. parity_matched stays false either way.
                climate_ok = _climate_authority.commit_day_forced(
                    climate_day, *trace_frame.reference_store,
                    climate_report);
                _climate_parity_forced_days.fetch_add(1,
                                                      std::memory_order_relaxed);
                if (!climate_ok && climate_report.error[0] == '\0') {
                    runtime_copy_text(climate_report.error,
                                      "climate_forced_commit_failed");
                }
                if (climate_ok) {
                    _climate_committed_day.store(climate_day,
                                                 std::memory_order_release);
                }
                runtime_copy_text(climate_report.parity_reason,
                                  "climate_reference_mismatch_forced");
            } else {
                // Abort before commit so a failed deterministic comparison
                // cannot advance the worker-owned Climate generation/day.
                _climate_authority.discard_plan();
                climate_report.completed = 0;
                climate_ok = false;
                climate_report.preflight_ok = 0;
                runtime_copy_text(climate_report.error,
                                  climate_report.parity_reason);
            }
        } else {
            // Record the agreeing day too, so a field's divergence rate is
            // out of the days it was actually compared rather than out of
            // the days it happened to fail.
            if (trace_frame.reference_store != nullptr) {
                accumulate_climate_parity_fields(
                    climate_day, *trace_frame.reference_store,
                    _climate_authority.planned_store());
            }
            // Only a matching next-state hash may cross the commit
            // boundary. The kernel's plan hash is identical to the
            // committed hash because commit only swaps the two lanes.
            climate_ok = _climate_authority.commit_day(
                climate_day, climate_report);
            if (!climate_ok) {
                climate_report.parity_reason[0] = '\0';
                if (climate_report.error[0] == '\0') {
                    runtime_copy_text(climate_report.error,
                                      "climate_commit_failed");
                }
            } else {
                // Drop any divergence recorded for an earlier day so a
                // stale field name cannot be read as today's result.
                clear_climate_parity_divergence();
                runtime_copy_text(climate_report.parity_reason, "ok");
                // B8 P0：SHADOW 也推进交付游标。诊断报告里的
                // climate_committed_day 不能只在 ACTIVE 下有意义，否则
                // 同一份 CSV 在两种模式间不可比。
                _climate_committed_day.store(climate_day,
                                             std::memory_order_release);
            }
        }
        }
        for (size_t i = 0; i < _climate_pod_parity_reason.size(); ++i) {
            _climate_pod_parity_reason[i].store(climate_report.parity_reason[i],
                                                std::memory_order_release);
            if (climate_report.parity_reason[i] == '\0') break;
        }
        _climate_pod_reference_hash.store(trace_frame.reference_state_hash,
                                           std::memory_order_release);
        _climate_parity_day.store(climate_day, std::memory_order_release);
        _climate_parity_input_generation.store(climate_report.input_generation, std::memory_order_release);
        _climate_parity_base_generation.store(_climate_authority.store().generation, std::memory_order_release);
        _climate_parity_trace_hash.store(trace_frame.trace_hash, std::memory_order_release);
        _climate_pod_parity_compared.store(climate_report.parity_compared != 0,
                                            std::memory_order_release);
        _climate_pod_parity_matched.store(climate_report.parity_matched != 0,
                                           std::memory_order_release);
        if (climate_report.parity_compared && !climate_report.parity_matched) {
            _climate_pod_parity_mismatch_count.fetch_add(1,
                                                          std::memory_order_relaxed);
        }
    } else {
        std::memset(&climate_report, 0, sizeof(climate_report));
        const char *reason = "climate_trace_reference_pending";
        if (trace_result == RuntimeClimateTracePopResult::EMPTY) {
            reason = "climate_trace_missing";
        } else if (trace_result == RuntimeClimateTracePopResult::FUTURE_FRAME) {
            reason = "climate_trace_future_frame";
        }
        runtime_copy_text(climate_report.error, reason);
        climate_report.preflight_ok = 0;
    }
    _climate_pod_ready.store(climate_ok, std::memory_order_release);
    // 停在 barrier（缺帧 / future / 日错位）时不要把上一帧已经提交的
    // climate_pod_state_hash 和 stage 诊断写成 0。worker 会立刻重试同一日，
    // 主线程读到的就会是“Climate 从未跑过”。
    const bool climate_diagnostics_fresh =
        climate_cold_start ||
        (climate_environment != nullptr && climate_day == plan.context.day);
    if (climate_diagnostics_fresh) {
        _climate_pod_plan_ms.store(climate_report.plan_ms, std::memory_order_release);
        _climate_pod_replay_ms.store(climate_report.replay_ms, std::memory_order_release);
        _climate_pod_work_units.store(climate_report.work_units, std::memory_order_release);
        _climate_pod_changed_cells.store(climate_report.changed_cells, std::memory_order_release);
        for (size_t i = 0; i < _climate_stage_ms.size() &&
                           i < climate_report.stage_ms.size(); ++i) {
            _climate_stage_ms[i].store(climate_report.stage_ms[i],
                                       std::memory_order_relaxed);
            _climate_stage_work[i].store(climate_report.stage_work[i],
                                       std::memory_order_relaxed);
        }
        _climate_pod_state_hash.store(climate_report.state_hash, std::memory_order_release);
        _climate_production_stage_mask.store(climate_report.production_stage_mask,
                                            std::memory_order_release);
        _climate_worker_stage_mask.store(climate_report.worker_stage_mask,
                                        std::memory_order_release);
        _climate_cyclone_alive.store(climate_report.cyclone_alive,
                                     std::memory_order_release);
        _climate_cyclone_injected.store(climate_report.cyclone_injected,
                                        std::memory_order_release);
        _climate_cyclone_replaced.store(climate_report.cyclone_replaced,
                                        std::memory_order_release);
        _climate_cyclone_decayed.store(climate_report.cyclone_decayed,
                                       std::memory_order_release);
        _climate_cyclone_touched.store(climate_report.cyclone_touched,
                                       std::memory_order_release);
    }
    for (size_t i = 0; i < _climate_pod_fallback_reason.size(); ++i) {
        _climate_pod_fallback_reason[i].store(climate_report.error[i],
                                              std::memory_order_release);
        if (climate_report.error[i] == '\0') break;
    }

    RuntimeDayContext diagnostic_context = plan.context;
    diagnostic_context.input_generation = climate_environment != nullptr
        ? climate_environment->generation : 0;

    // K2-A vertical slice: when a Country capture/catalog pair was
    // published before this worker started, the worker owns a persistent
    // Country POD plan. A missing peer result parks this whole semantic
    // boundary; it must not fall through to the old per-call diagnostic
    // adapter or advance the worker clock.
    if (climate_ok && _country_pod_configured) {
        std::string country_error;
        if (!execute_country_worker_stage(
                plan.context.day, diagnostic_context.input_generation,
                day_commands, commit, country_error,
                admitted_submit_order)) {
            static std::atomic<int> s_country_boundary_errors_left{8};
            if (s_country_boundary_errors_left.fetch_sub(
                    1, std::memory_order_relaxed) > 0) {
                std::fprintf(stderr,
                             "[country][boundary] day=%lld failed=%s "
                             "climate_day=%lld input_generation=%llu\n",
                             static_cast<long long>(plan.context.day),
                             country_error.empty() ? "country_worker_stage_pending" :
                                 country_error.c_str(),
                             static_cast<long long>(climate_day),
                             static_cast<unsigned long long>(
                                 diagnostic_context.input_generation));
                std::fflush(stderr);
            }
            _country_pod_ready.store(false, std::memory_order_release);
            const char *reason = country_error.empty()
                ? "country_worker_stage_pending" : country_error.c_str();
            for (size_t i = 0; i + 1 < _country_pod_fallback_reason.size(); ++i) {
                _country_pod_fallback_reason[i].store(reason[i],
                                                     std::memory_order_release);
                if (reason[i] == '\0') break;
            }
            _country_pod_fallback_reason[_country_pod_fallback_reason.size() - 1]
                .store('\0', std::memory_order_release);
            commit.preflight_ok = 0;
            return commit;
        }
        _country_pod_ready.store(true, std::memory_order_release);
    }

    // G7 SHADOW stage. It consumes the Country snapshot committed above
    // and the previous main-thread Economy opinion publication. Failure
    // is diagnostic only and never stalls Climate or promotes IDEOLOGY.
    // This whole block is SHADOW-only; G8 ACTIVE Ideology runs from the
    // stage loop below, where a failure isolates the domain instead of
    // being folded into the Climate/Country diagnostic chain.
    std::string ideology_error;
    const auto ideology_outcome = climate_ok ? execute_ideology_worker_stage(
        plan.context.day, commit, ideology_error) : IdeologyStageOutcome::PARKED;
    const bool ideology_ok = ideology_outcome == IdeologyStageOutcome::COMMITTED ||
        ideology_outcome == IdeologyStageOutcome::ALREADY_COMMITTED;
    _ideology_pod_ready.store(ideology_ok, std::memory_order_release);
    const char *ideology_reason = ideology_ok
        ? (_ideology_pod_pending_transition_count.load(
                std::memory_order_acquire) > 0
            ? "ideology_effect_ack_pending" : "")
        : (ideology_error.empty() ? "ideology_pod_plan_failed" :
                                  ideology_error.c_str());
    size_t ideology_reason_index = 0;
    for (; ideology_reason_index + 1 < _ideology_pod_fallback_reason.size() &&
           ideology_reason[ideology_reason_index] != '\0';
         ++ideology_reason_index) {
        _ideology_pod_fallback_reason[ideology_reason_index].store(
            ideology_reason[ideology_reason_index], std::memory_order_release);
    }
    for (; ideology_reason_index < _ideology_pod_fallback_reason.size();
         ++ideology_reason_index) {
        _ideology_pod_fallback_reason[ideology_reason_index].store(
            '\0', std::memory_order_release);
    }

    // F7 SHADOW Effect stage. Runs after Ideology and before Modifier so
    // real Effect POD intents can replace diagnostic run_effect fixtures
    // as the Modifier upstream. An empty cold-start catalog does not enable
    // the stage, so Modifier E7 keeps its fixture upstream until a real
    // Effect catalog is configured. Failure is diagnostic only and never
    // stalls Climate/Country or grants EFFECT ACTIVE authority.
    std::string effect_error;
    bool effect_ok = false;
    const bool effect_stage_enabled =
        _effect_pod_configured && !_effect_pod_catalog.definitions.empty();
    if (effect_stage_enabled) {
        effect_ok = execute_effect_worker_stage(
            plan.context.day, diagnostic_context.input_generation,
            commit, effect_error);
    } else {
        _effect_day_modifier_intents.clear();
        _effect_day_stage_ok = false;
        effect_error = _effect_pod_configured
            ? "effect_pod_catalog_empty" : "effect_pod_not_configured";
    }
    _effect_pod_ready.store(effect_ok, std::memory_order_release);
    const char *effect_reason = effect_ok ? "" :
        (effect_error.empty() ? "effect_pod_plan_failed" :
                                effect_error.c_str());
    size_t effect_reason_index = 0;
    for (; effect_reason_index + 1 < _effect_pod_fallback_reason.size() &&
           effect_reason[effect_reason_index] != '\0';
         ++effect_reason_index) {
        _effect_pod_fallback_reason[effect_reason_index].store(
            effect_reason[effect_reason_index], std::memory_order_release);
    }
    for (; effect_reason_index < _effect_pod_fallback_reason.size();
         ++effect_reason_index) {
        _effect_pod_fallback_reason[effect_reason_index].store(
            '\0', std::memory_order_release);
    }

    // Run the consolidated worker-only domain transaction after the
    // Climate trace barrier. This is deliberately a SHADOW diagnostic:
    // it owns an isolated aggregate and never contributes to the
    // authoritative clock, MapData, or implemented-domain mask.
    RuntimeDomainAuthorityPlan authority_plan;
    std::string authority_error;
    bool authority_ok = false;
    double authority_plan_ms = 0.0;
    double authority_replay_ms = 0.0;
    if (climate_ok && climate_environment != nullptr) {
        const auto &authority_stores = _domain_authority_runner.stores();
        const uint32_t country_count = country_snapshot != nullptr
            ? country_snapshot->country_count : authority_stores.country.country_count;
        if (authority_stores.climate.cell_count !=
                climate_environment->cell_count ||
            authority_stores.country.country_count != country_count ||
            authority_stores.country.cell_count !=
                climate_environment->cell_count) {
            _domain_authority_runner.reset(
                climate_environment->cell_count, country_count);
        }
        RuntimeDayContext authority_context = diagnostic_context;
        authority_context.environment = climate_environment;
        const auto plan_started = std::chrono::steady_clock::now();
        authority_ok = _domain_authority_runner.plan_day(
            authority_context, climate_environment,
            country_snapshot.get(), authority_plan, authority_error);
        authority_plan_ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - plan_started).count();
        if (authority_ok) {
            // F7/E8: Effect POD upstream when catalog is non-empty and the
            // Effect stage succeeded. Strip fixture MODIFIER intents so the
            // domain-runner ACK barrier does not wait on a second Effect
            // writer. Empty cold-start catalogs keep fixture upstream for
            // Modifier E7.
            const bool use_effect_pod_upstream =
                effect_stage_enabled && _effect_day_stage_ok;
            if (use_effect_pod_upstream) {
                std::vector<RuntimeDomainIntent> retained_intents;
                retained_intents.reserve(authority_plan.intents.size());
                for (const RuntimeDomainIntent &intent : authority_plan.intents) {
                    if (intent.target_domain ==
                        static_cast<uint16_t>(RuntimeDomainId::MODIFIER)) {
                        continue;
                    }
                    retained_intents.push_back(intent);
                }
                authority_plan.intents.swap(retained_intents);
                authority_plan.ack_required_mask &=
                    ~runtime_domain_mask(RuntimeDomainId::MODIFIER);
            }
            std::string modifier_error;
            const auto modifier_started = std::chrono::steady_clock::now();
            const bool modifier_ok = execute_modifier_worker_stage(
                plan.context.day, diagnostic_context.input_generation,
                day_commands, use_effect_pod_upstream, &authority_plan,
                authority_error, modifier_error);
            authority_ok = modifier_ok;
            authority_replay_ms = std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - modifier_started).count();
            if (!modifier_ok && authority_error.empty())
                authority_error = modifier_error;
        } else {
            _domain_authority_runner.discard_plan();
        }
    } else {
        authority_error = climate_report.error[0] != '\0'
            ? climate_report.error : "climate_reference_barrier_pending";
        _domain_authority_runner.discard_plan();
    }
    if (authority_ok) {
        const RuntimeDomainAuthorityReport &authority_report =
            _domain_authority_runner.report();
        const RuntimeEconomyReplayReport &economy_replay =
            _domain_authority_runner.economy_replay_report();
        _economy_replay_completed_stage_mask.store(
            economy_replay.completed_stage_mask, std::memory_order_release);
        _economy_replay_stage_cursor.store(
            economy_replay.stage_cursor, std::memory_order_release);
        _economy_replay_input_hash.store(
            economy_replay.input_hash, std::memory_order_release);
        _economy_replay_base_hash.store(
            economy_replay.base_hash, std::memory_order_release);
        _economy_replay_next_hash.store(
            economy_replay.next_hash, std::memory_order_release);
        for (size_t i = 0; i < RuntimeEconomyReplayReport::STAGE_COUNT; ++i) {
            _economy_replay_stage_hash[i].store(
                economy_replay.stage_hash[i], std::memory_order_release);
            _economy_replay_stage_work[i].store(
                economy_replay.stage_work[i], std::memory_order_release);
            _economy_replay_stage_ms[i].store(
                economy_replay.stage_ms[i], std::memory_order_release);
        }
        _economy_replay_input_captured.store(
            economy_replay.input_captured != 0, std::memory_order_release);
        _economy_replay_committed.store(
            economy_replay.committed != 0, std::memory_order_release);
        _economy_replay_parity_ready.store(
            economy_replay.parity_ready != 0, std::memory_order_release);
        for (size_t i = 0; i < _economy_replay_fallback_reason.size(); ++i) {
            _economy_replay_fallback_reason[i].store(
                economy_replay.fallback_reason[i], std::memory_order_release);
            if (economy_replay.fallback_reason[i] == '\0') break;
        }
        // Dedicated Economy SHADOW stage handler (J2-B). Replays the same
        // epoch contract through RuntimeEconomyPodAuthority; does not grant
        // ACTIVE mask.
        if (economy_parity_shadow_enabled()) {
            std::string economy_stage_error;
            const uint32_t economy_cells =
                climate_environment != nullptr
                    ? climate_environment->cell_count : 0u;
            const uint64_t economy_catalog =
                climate_environment != nullptr
                    ? climate_environment->generation : 0u;
            const uint64_t economy_country_generation =
                country_snapshot != nullptr ? country_snapshot->generation : 0u;
            if (economy_cells > 0u) {
                (void)execute_economy_worker_stage(
                    diagnostic_context.day,
                    diagnostic_context.input_generation, economy_cells,
                    economy_country_generation, economy_catalog,
                    economy_stage_error);
            }
        }
        _domain_authority_planned_mask.store(
            authority_report.diagnostic_planned_mask,
            std::memory_order_release);
        _domain_authority_committed_mask.store(
            authority_report.diagnostic_committed_mask,
            std::memory_order_release);
        _domain_authority_ack_count.store(authority_report.ack_count,
                                          std::memory_order_release);
        _domain_authority_input_hash.store(authority_report.input_hash,
                                           std::memory_order_release);
        _domain_authority_state_hash.store(authority_report.state_hash,
                                           std::memory_order_release);
        _domain_authority_plan_ms.store(authority_plan_ms,
                                        std::memory_order_release);
        _domain_authority_replay_ms.store(authority_replay_ms,
                                          std::memory_order_release);
        for (size_t i = 0; i < _domain_authority_fallback_reason.size(); ++i) {
            _domain_authority_fallback_reason[i].store('\0',
                                                      std::memory_order_release);
        }
    } else {
        _domain_authority_planned_mask.store(0, std::memory_order_release);
        _domain_authority_committed_mask.store(0, std::memory_order_release);
        _domain_authority_ack_count.store(0, std::memory_order_release);
        _domain_authority_input_hash.store(0, std::memory_order_release);
        _domain_authority_state_hash.store(0, std::memory_order_release);
        _domain_authority_plan_ms.store(authority_plan_ms,
                                        std::memory_order_release);
        _domain_authority_replay_ms.store(authority_replay_ms,
                                          std::memory_order_release);
        const char *reason = authority_error.empty()
            ? "domain_authority_plan_failed" : authority_error.c_str();
        size_t i = 0;
        for (; i + 1 < _domain_authority_fallback_reason.size() &&
                reason[i] != '\0'; ++i) {
            _domain_authority_fallback_reason[i].store(
                reason[i], std::memory_order_release);
        }
        for (; i < _domain_authority_fallback_reason.size(); ++i) {
            _domain_authority_fallback_reason[i].store(
                '\0', std::memory_order_release);
        }
    }
    uint32_t stage_fallback_count = 0;
    char first_stage_fallback[64]{};
    for (const RuntimeDomainId domain : runtime_domain_stage_order()) {
        if (domain == RuntimeDomainId::COMMIT) continue;
        const RuntimeDomainReport stage_report =
            _authoritative_domains.stage_preflight(
                domain, diagnostic_context, climate_environment);
        if (stage_report.fallback != 0 || stage_report.preflight_ok == 0) {
            ++stage_fallback_count;
            if (first_stage_fallback[0] == '\0') {
                runtime_copy_text(first_stage_fallback,
                                  stage_report.fallback_reason);
            }
        }
    }
    _domain_stage_fallback_count.store(stage_fallback_count,
                                       std::memory_order_release);
    for (size_t i = 0; i < _domain_stage_fallback_reason.size(); ++i) {
        _domain_stage_fallback_reason[i].store(first_stage_fallback[i],
                                               std::memory_order_release);
        if (first_stage_fallback[i] == '\0') break;
    }
    _pod_visual_intents.clear();
    _pod_receipts.clear();
    const bool pipeline_ok = _pod_pipeline.execute_day(
        diagnostic_context, climate_environment, country_snapshot.get(),
        commit, _pod_visual_intents, _pod_receipts);
    const RuntimeDomainPipelineReport &pipeline_report = _pod_pipeline.report();
    RuntimeEconomyPodSnapshot economy_snapshot;
    _pod_pipeline.snapshot_economy(economy_snapshot);
    _economy_pod_ready.store(
        pipeline_report.domains[static_cast<size_t>(RuntimeDomainId::ECONOMY) - 1u].completed != 0,
        std::memory_order_release);
    _economy_pod_committed.store(economy_snapshot.committed,
                                 std::memory_order_release);
    _economy_pod_authority_ready.store(economy_snapshot.authority_ready,
                                        std::memory_order_release);
    _economy_pod_committed_day.store(economy_snapshot.committed_day,
                                     std::memory_order_release);
    _economy_pod_epoch_sample_day.store(economy_snapshot.epoch_sample_day,
                                        std::memory_order_release);
    _economy_pod_generation.store(economy_snapshot.generation,
                                   std::memory_order_release);
    _economy_pod_state_hash.store(economy_snapshot.state_hash,
                                  std::memory_order_release);
    _economy_pod_input_generation.store(economy_snapshot.input_generation,
                                        std::memory_order_release);
    _economy_pod_country_generation.store(economy_snapshot.country_generation,
                                          std::memory_order_release);
    _economy_pod_completed_stage_mask.store(economy_snapshot.completed_stage_mask,
                                            std::memory_order_release);
    _economy_pod_pending_outbox.store(economy_snapshot.pending_outbox,
                                      std::memory_order_release);
    _economy_pod_pending_inbox.store(economy_snapshot.pending_inbox,
                                     std::memory_order_release);
    _economy_pod_operation_gate_mask.store(economy_snapshot.operation_gate_mask,
                                           std::memory_order_release);
    _pod_completed_domain_mask.store(pipeline_report.completed_domain_mask,
                                     std::memory_order_release);
    _pod_completed_stage_count.store(
        pipeline_ok ? RUNTIME_DOMAIN_STAGE_COUNT : 0u,
        std::memory_order_release);
    _pod_work_units.store(pipeline_report.work_units, std::memory_order_release);
    _pod_intent_count.store(pipeline_report.intent_count, std::memory_order_release);
    _pod_fallback_count.store(pipeline_report.fallback_count, std::memory_order_release);
    // Do not leak shadow intents into the visual ring. They are only
    // consumed by parity tooling until the ACTIVE ownership gate clears.
    commit.completed_stage_count = 1;
    commit.completed_domain_mask = runtime_domain_mask(RuntimeDomainId::COMMIT);
    commit.dirty_families = RUNTIME_DIRTY_CLOCK;
    commit.work_units = std::max<uint64_t>(1, pipeline_report.work_units);
    commit.preflight_ok = climate_ok ? 1u : 0u;
    run_day_events(day, plan.context.day);
    return commit;

}
} // namespace pk

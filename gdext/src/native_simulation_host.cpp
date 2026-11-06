#include "economy_authority_transfer.h"
#include "economy_invariant_probe.h"
#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#endif
#include "native_simulation_host.h"
#include "native_simulation_host_support.h"
#include "native_simulation_day_context.h"
#include "runtime_module_descriptor.h"
#include <cassert>
#include "country_core_apply.h"
#include "country_ai_runtime.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "effect_magnitude.h"
#include "runtime_economy_ecp2.h"
#include "native_parallel_executor.h"
#include "runtime_climate_parity.h"
#include "runtime_switch_registry.h"
#include "pk_log.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <exception>
#include <limits>
#include <type_traits>
#include <unordered_set>

#if defined(_WIN32)
#include <windows.h>
#endif

namespace pk {

NativeSimulationHost::ControlState NativeSimulationHost::control_state() const {
    ControlState out;
    out.state = _state.load(std::memory_order_acquire);
    out.mode = _mode.load(std::memory_order_acquire);
    const auto authority = _authority_control.snapshot();
    out.authority_ready = authority.ready;
    out.interactive = _interactive.load(std::memory_order_acquire);
    out.authoritative_domain_mask = authority.granted_mask;
    out.committed_day = _committed_day.load(std::memory_order_acquire);
    return out;
}

bool NativeSimulationHost::execution_has_stopped() const {
    const auto state = _state.load(std::memory_order_acquire);
    return (state == RuntimeWorkerState::STOPPED || state == RuntimeWorkerState::FAULTED) &&
        _worker_returned->load(std::memory_order_acquire) &&
        _worker_day_inflight.load(std::memory_order_acquire) == 0u;
}

bool NativeSimulationHost::annual_worker_managed() const {
    const auto required = runtime_domain_mask(RuntimeDomainId::COUNTRY) | runtime_domain_mask(RuntimeDomainId::IDEOLOGY);
    return state() != RuntimeWorkerState::STOPPED &&
        _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE &&
        (_requested_authority_mask.load(std::memory_order_acquire) & required) == required;
}


namespace {


// "<tag>.plan.before" / "<tag>.plan.after" so soak harnesses can arm one shot
// faults without knowing stage indices.
const char *runtime_domain_fault_tag(RuntimeDomainId domain) noexcept {
    switch (domain) {
    case RuntimeDomainId::INPUT_CAPTURE: return "input_capture";
    case RuntimeDomainId::CLIMATE: return "climate";
    case RuntimeDomainId::COUNTRY: return "country";
    case RuntimeDomainId::TRIGGER_INPUT: return "trigger_input";
    case RuntimeDomainId::IDEOLOGY: return "ideology";
    case RuntimeDomainId::EFFECT: return "effect";
    case RuntimeDomainId::MODIFIER: return "modifier";
    case RuntimeDomainId::GAMEPLAY_EFFECT: return "gameplay_effect";
    case RuntimeDomainId::ECONOMY: return "economy";
    case RuntimeDomainId::EVENTS: return "events";
    case RuntimeDomainId::VISUAL: return "visual";
    case RuntimeDomainId::COMMIT: return "commit";
    }
    return "unknown";
}

}

NativeSimulationHost::NativeSimulationHost() {
    _pod_visual_intents.reserve(RUNTIME_DOMAIN_INTENT_CAPACITY);
    _pod_receipts.reserve(RUNTIME_RECEIPT_QUEUE_CAPACITY);
    for (auto &sequence : _producer_sequences) {
        sequence.store(0, std::memory_order_relaxed);
    }
    for (uint64_t i = 0; i < RUNTIME_COMMAND_QUEUE_CAPACITY; ++i) {
        _command_slots[i].sequence.store(i, std::memory_order_relaxed);
    }
    for (auto &generation : _dirty_family_generations) {
        generation.store(0, std::memory_order_relaxed);
    }
    for (auto &character : _fault_code) character.store('\0', std::memory_order_relaxed);
    _fault_injection_armed.store(false, std::memory_order_relaxed);
    _fault_injection_trip_count.store(0, std::memory_order_relaxed);
    for (auto &character : _fault_injection_point)
        character.store('\0', std::memory_order_relaxed);
    for (auto &character : _economy_authority_switch_reason)
        character.store('\0', std::memory_order_relaxed);
    for (auto &character : _economy_authority_switch_blocker)
        character.store('\0', std::memory_order_relaxed);
    for (auto &character : _economy_authority_switch_audit_before)
        character.store('\0', std::memory_order_relaxed);
    for (auto &character : _economy_authority_switch_audit_after)
        character.store('\0', std::memory_order_relaxed);
    for (auto &sample : _economy_authority_switch_latency_samples)
        sample.store(0, std::memory_order_relaxed);
    for (auto &sample : _economy_authority_switch_command_latency_samples)
        sample.store(0, std::memory_order_relaxed);
    for (auto &character : _domain_authority_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    for (auto &character : _modifier_pod_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    _effect_pod_ready.store(false, std::memory_order_release);
    _effect_pod_plan_ms.store(0.0, std::memory_order_release);
    _effect_pod_replay_ms.store(0.0, std::memory_order_release);
    _effect_pod_state_hash.store(0, std::memory_order_release);
    _effect_pod_snapshot_generation.store(0, std::memory_order_release);
    _effect_pod_ack_count.store(0, std::memory_order_release);
    _effect_pod_intent_count.store(0, std::memory_order_release);
    _effect_pod_managed_intent_count.store(0, std::memory_order_release);
    _effect_pod_unmanaged_intent_count.store(0, std::memory_order_release);
    _effect_pod_program_intent_count.store(0, std::memory_order_release);
    for (auto &program_id : _effect_pod_intent_program_ids)
        program_id.store(-1, std::memory_order_relaxed);
    _effect_pod_transaction_count.store(0, std::memory_order_release);
    _effect_retire_absent_count.store(0, std::memory_order_release);
    _effect_retire_stale_count.store(0, std::memory_order_release);
    _effect_day_stage_ok = false;
    _effect_day_modifier_intents.clear();
    _effect_day_intents.clear();
    for (auto &character : _effect_pod_fallback_reason)
        character.store('\0', std::memory_order_relaxed);
    _ideology_pod_ready.store(false, std::memory_order_release);
    _ideology_pod_plan_ms.store(0.0, std::memory_order_release);
    _ideology_pod_replay_ms.store(0.0, std::memory_order_release);
    _ideology_pod_state_hash.store(0, std::memory_order_release);
    _ideology_pod_snapshot_generation.store(0, std::memory_order_release);
    _ideology_pod_pending_transition_count.store(0, std::memory_order_release);
    _ideology_pod_intent_count.store(0, std::memory_order_release);
    for (auto &character : _ideology_pod_fallback_reason)
        character.store('\0', std::memory_order_relaxed);
    for (auto &character : _events_pod_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    for (auto &character : _ideology_pod_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    _country_pod_ready.store(false, std::memory_order_relaxed);
    for (auto &character : _country_pod_fallback_reason) {
        character.store('\0', std::memory_order_relaxed);
    }
    // Keep the PKSR contract uniform even before the main-thread Effect
    // catalog is loaded. An empty catalog is a valid cold-start POD authority;
    // configure_effects() replaces it before any Effect instance can run.
    std::string effect_config_error;
    if (_effect_pod_authority.configure(_effect_pod_catalog,
                                        effect_config_error)) {
        _effect_pod_catalog.catalog_hash = _effect_pod_authority.catalog_hash();
        _effect_pod_configured = true;
    }
}

NativeSimulationHost::~NativeSimulationHost() {
    request_stop();
    join_for_destruction();
}

bool NativeSimulationHost::reap_completed_worker_nonblocking() {
    return _retired_workers.retire(_worker);
}

uint64_t NativeSimulationHost::now_us() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}

uint64_t NativeSimulationHost::mix_hash(uint64_t value, uint64_t input) {
    value ^= input + 0x9e3779b97f4a7c15ull + (value << 6) + (value >> 2);
    value *= 1099511628211ull;
    return value;
}

RuntimeDayCommit NativeSimulationHost::execute_day_plan(
        RuntimeDayPlan &plan,
        const RuntimeEnvironmentSnapshot *environment,
        const std::vector<RuntimeCommandPacket> &day_commands,
        std::vector<RuntimeCommandReceipt> &day_receipts,
        uint64_t admitted_submit_order) {
    RuntimeDayCommit commit;
    // native_daily_inline 分域计时开关。worker 日恒为 false，所以这条 worker 路径
    // 不为任何探针付账（只有每 stage 一次原子读）。内联日一切都在调用线程上，
    // 累加器不需要原子。
    const bool inline_timing = inline_daily_mode();
    const auto timing_started = std::chrono::steady_clock::now();
    // 单日墙钟预算：只在 stage 之间检查（不切半截 stage），目的是"浏览器里绝不
    // 无限挂死"。默认 30s，PK_INLINE_DAY_BUDGET_MS=0 关掉。
    const int64_t day_budget_us = inline_timing
        ? inline_day_budget_us() : 0;
    if (inline_timing) {
        _inline_stage_ms.fill(0.0);
        _inline_pre_stage_ms = 0.0;
        _inline_climate_ms = 0.0;
        _inline_budget_exceeded = false;
    }
    if (try_fault_injection("day.plan.before")) {
        commit.preflight_ok = 0;
        return commit;
    }
    _pod_visual_intents.clear();
    // INPUT_CAPTURE is a real freeze boundary, not merely a validation bit.
    // 仅复用本次调用中、同一不可变对象已经由 Climate kernel 计算的完整哈希。
    // 不按 day/generation 猜测跨调用内容；重试或未跑 Climate 时仍完整计算。
    DayExecution day{plan, environment, day_commands, day_receipts,
                     admitted_submit_order, commit};
    auto &climate_authority_requested = day.climate_authority_requested;
    auto &active_climate_ok = day.active_climate_ok;
    // SHADOW retains its diagnostic pipeline; ACTIVE uses the module table.
    if (_mode.load(std::memory_order_acquire) == RuntimeSimulationMode::SHADOW) {
        return execute_shadow_day(day);
    }
    // Preserve the production ordering: Climate computes before INPUT_CAPTURE.
    // Moving that commit into the table would change retries and is a later migration.
    _day_waterfall.mark(RuntimeDayWaterfall::PRE_SETUP);
    // 内联日：Climate 内核在 12 域循环之前就算完了。单独计时后并进
    // stage_ms[CLIMATE]——否则分域表会把这一天最贵的一段记成 0，读表的人会
    // 以为 Climate 是免费的。
    const auto climate_kernel_started = std::chrono::steady_clock::now();
    prepare_climate_day(day);

    _day_waterfall.mark(RuntimeDayWaterfall::CLIMATE_COMPUTE);
    if (inline_timing) {
        const auto climate_kernel_finished = std::chrono::steady_clock::now();
        _inline_climate_ms = std::chrono::duration<double, std::milli>(
            climate_kernel_finished - climate_kernel_started).count();
        _inline_stage_ms[static_cast<uint32_t>(RuntimeDomainId::CLIMATE) - 1u] +=
            _inline_climate_ms;
        _inline_pre_stage_ms = std::chrono::duration<double, std::milli>(
            climate_kernel_finished - timing_started).count();
    }
    // 内联日分域计时器：作用域结束（continue / return 都算）时把这一段的耗时
    // 记到它自己的域下标上。worker 日 enabled=false，只剩一次布尔判断。
    struct InlineStageTimer {
        std::array<double, RUNTIME_DOMAIN_STAGE_COUNT> *slots = nullptr;
        RuntimeDomainId domain = RuntimeDomainId::INPUT_CAPTURE;
        std::chrono::steady_clock::time_point started{};
        bool enabled = false;
        ~InlineStageTimer() {
            if (!enabled || slots == nullptr) return;
            const uint32_t index = static_cast<uint32_t>(domain);
            if (index < 1u ||
                index > static_cast<uint32_t>(slots->size())) return;
            (*slots)[index - 1u] += std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now() - started).count();
        }
    };
    RuntimeDomainId previous_domain = RuntimeDomainId::INPUT_CAPTURE;
    bool previous_domain_valid = false;
    using StageFunction = bool (NativeSimulationHost::*)(DayExecution &, RuntimeDomainPlan &);
    static constexpr std::array<RuntimeModuleDescriptor<StageFunction>, RUNTIME_DOMAIN_STAGE_COUNT> modules{{
        {"input_capture", RuntimeDomainId::INPUT_CAPTURE, &NativeSimulationHost::stage_input_capture,
         "environment, committed country/catalog/resource generations", "input manifest", false, &runtime_module_contracts[0]},
        {"climate", RuntimeDomainId::CLIMATE, &NativeSimulationHost::stage_climate,
         "pre-loop climate result", "stage completion; climate store committed in prelude", false, &runtime_module_contracts[1]},
        {"country", RuntimeDomainId::COUNTRY, &NativeSimulationHost::stage_country,
         "climate, country commands, peer results", "country POD, peer intents", false, &runtime_module_contracts[2]},
        {"trigger_input", RuntimeDomainId::TRIGGER_INPUT, &NativeSimulationHost::stage_trigger_input,
         "country, committed events, effect ACKs", "trigger POD, effect intents", false, &runtime_module_contracts[3]},
        {"ideology", RuntimeDomainId::IDEOLOGY, &NativeSimulationHost::stage_ideology,
         "country, economy opinion, modifier ACKs", "ideology POD, modifier intents", false, &runtime_module_contracts[4]},
        {"effect", RuntimeDomainId::EFFECT, &NativeSimulationHost::stage_effect,
         "trigger/ideology/country intents, metrics", "effect POD, modifier/event intents", false, &runtime_module_contracts[5]},
        {"modifier", RuntimeDomainId::MODIFIER, &NativeSimulationHost::stage_modifier,
         "effect and ideology intents", "modifier POD, ACKs", false, &runtime_module_contracts[6]},
        {"gameplay_effect", RuntimeDomainId::GAMEPLAY_EFFECT, &NativeSimulationHost::stage_gameplay_effect,
         "typed gameplay commands", "events and ideology command queues, ingress summary", false, &runtime_module_contracts[7]},
        {"economy", RuntimeDomainId::ECONOMY, &NativeSimulationHost::stage_economy,
         "climate, country, modifier, frozen economy input", "economy runtime/OwnedState, country/effect peer intents", false, &runtime_module_contracts[8]},
        {"events", RuntimeDomainId::EVENTS, &NativeSimulationHost::stage_events,
         "day commands, gameplay/economy event commands", "event journal and consumer cursors, trigger ingress", false, &runtime_module_contracts[9]},
        {"visual", RuntimeDomainId::VISUAL, &NativeSimulationHost::stage_visual,
         "day dirty families", "POD visual intents", false, &runtime_module_contracts[10]},
        {"commit", RuntimeDomainId::COMMIT, &NativeSimulationHost::stage_commit,
         "stage results", "day commit header (publication follows loop)", false, &runtime_module_contracts[11]},
    }};
    static_assert(runtime_module_order_matches(modules), "day modules must match protocol order");
    assert(plan.stage_count == modules.size());
    for (uint32_t i = 0; i < modules.size(); ++i) {
        RuntimeDomainPlan &stage = plan.stages[i];
        if (previous_domain_valid) {
            _day_waterfall.mark(RuntimeDayWaterfall::domain(
                static_cast<uint16_t>(previous_domain)));
            char after_point[72];
            std::snprintf(after_point, sizeof(after_point), "%s.plan.after",
                          runtime_domain_fault_tag(previous_domain));
            if (try_fault_injection(after_point)) {
                commit.preflight_ok = 0;
                return commit;
            }
        }
        {
            char before_point[72];
            std::snprintf(before_point, sizeof(before_point), "%s.plan.before",
                          runtime_domain_fault_tag(stage.domain));
            if (try_fault_injection(before_point)) {
                commit.preflight_ok = 0;
                return commit;
            }
        }
        previous_domain = stage.domain;
        previous_domain_valid = true;
        // 单日墙钟预算看门狗：只在 stage 之间判断，绝不切开半截 stage。
        // 超预算就带着 preflight_ok=0 收工 —— 浏览器里一次有界的失败远好过
        // 主线程被某一域永远钉住（此时页面连 WebTelemetry 心跳都发不出去）。
        if (inline_timing && day_budget_us > 0 &&
            std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now() - timing_started).count() >
                day_budget_us) {
            _inline_budget_exceeded = true;
            commit.preflight_ok = 0;
            commit.continuation_pending = 0;
            return commit;
        }
        InlineStageTimer stage_timer{&_inline_stage_ms, stage.domain,
                                     std::chrono::steady_clock::now(),
                                     inline_timing};
        assert(stage.domain == modules[i].domain);
        if (!(this->*modules[i].stage)(day, stage)) return commit;
    }
    if (previous_domain_valid) {
        _day_waterfall.mark(RuntimeDayWaterfall::domain(
            static_cast<uint16_t>(previous_domain)));
        char after_point[72];
        std::snprintf(after_point, sizeof(after_point), "%s.plan.after",
                      runtime_domain_fault_tag(previous_domain));
        if (try_fault_injection(after_point)) {
            commit.preflight_ok = 0;
            return commit;
        }
    }
    // M5 atomic COMMIT gate: every domain explicitly requested for ACTIVE
    // authority must have completed before the worker clock or snapshot can
    // advance.  Unrequested domains remain on their legacy writer and are
    // intentionally absent from this mask.  This closes the old hole where a
    // missing stage could still let COMMIT publish a half-day.
    const uint32_t active_requested =
        _mode.load(std::memory_order_acquire) == RuntimeSimulationMode::ACTIVE
            ? _requested_authority_mask.load(std::memory_order_acquire) : 0u;
    if (active_requested != 0u &&
        (commit.completed_domain_mask & active_requested) != active_requested) {
        commit.preflight_ok = 0;
        commit.continuation_pending = 1;
    }
    run_day_events(day, plan.context.day);
    // A failed authoritative Climate day must not advance the clock. The main
    // thread is suppressed, so advancing anyway would silently drop that day:
    // nobody computed it and nothing would ever go back for it. Zero here parks
    // the worker on the same day until the input barrier clears.
    if (climate_authority_requested && !active_climate_ok) {
        commit.preflight_ok = 0;
    }
    if (try_fault_injection("day.plan.after")) {
        commit.preflight_ok = 0;
    }
    return commit;
}

void NativeSimulationHost::record_save_failure(const char *reason) {
    const char *value = reason ? reason : "unknown";
    size_t i = 0;
    for (; i + 1 < _save_failure_reason.size() && value[i] != '\0'; ++i)
        _save_failure_reason[i].store(value[i], std::memory_order_relaxed);
    for (; i < _save_failure_reason.size(); ++i)
        _save_failure_reason[i].store('\0', std::memory_order_relaxed);
}

std::string NativeSimulationHost::save_failure_reason() const {
    std::string out;
    for (const auto &c : _save_failure_reason) {
        const char value = c.load(std::memory_order_relaxed);
        if (value == '\0') break;
        out.push_back(value);
    }
    return out;
}

void NativeSimulationHost::set_fault(const char *code) {
    _worker_fault_count.fetch_add(1, std::memory_order_relaxed);
    // A faulted worker owns nothing. Same reason as request_stop: the schedule
    // gate must hand the domain back to the main thread rather than let a dead
    // worker keep it suppressed.
    _authority_control.revoke();
    const char *value = code ? code : "unknown";
    size_t i = 0;
    for (; i + 1 < _fault_code.size() && value[i] != '\0'; ++i) {
        _fault_code[i].store(value[i], std::memory_order_relaxed);
    }
    for (; i < _fault_code.size(); ++i) {
        _fault_code[i].store('\0', std::memory_order_relaxed);
    }
    _state.store(RuntimeWorkerState::FAULTED, std::memory_order_release);
    _economy_authority_fault_paused.store(true, std::memory_order_release);
    _economy_authority_last_committed_generation.store(
        _economy_pod_authority.committed_ledger_state().generation,
        std::memory_order_release);
    _economy_authority_last_committed_hash.store(
        _economy_pod_authority.state_hash(), std::memory_order_release);
    // Godot console often drops stderr-only; always surface the code.
    const std::string fault_line = pk::log_format(
        "[runtime-worker-fault] code=%s day=%d ring=%d",
        std::string(value).c_str(),
        _committed_day.load(std::memory_order_relaxed),
        static_cast<int64_t>(_environment_ring.size()));
    pk::log_line(fault_line);
    pk::log_line(fault_line, true);
}

bool NativeSimulationHost::arm_fault_injection(const char *point) noexcept {
    if (point == nullptr || point[0] == '\0') return false;
    size_t i = 0;
    for (; i + 1 < _fault_injection_point.size() && point[i] != '\0'; ++i) {
        _fault_injection_point[i].store(point[i], std::memory_order_relaxed);
    }
    if (point[i] != '\0') {
        // Reject truncated names so soak scripts cannot silently arm a
        // different boundary than the one they asked for.
        for (auto &character : _fault_injection_point)
            character.store('\0', std::memory_order_relaxed);
        _fault_injection_armed.store(false, std::memory_order_release);
        return false;
    }
    for (; i < _fault_injection_point.size(); ++i)
        _fault_injection_point[i].store('\0', std::memory_order_relaxed);
    _fault_injection_armed.store(true, std::memory_order_release);
    return true;
}

void NativeSimulationHost::clear_fault_injection() noexcept {
    _fault_injection_armed.store(false, std::memory_order_release);
    for (auto &character : _fault_injection_point)
        character.store('\0', std::memory_order_relaxed);
}

bool NativeSimulationHost::try_fault_injection(const char *point) noexcept {
    if (point == nullptr || point[0] == '\0') return false;
    if (!_fault_injection_armed.load(std::memory_order_acquire)) return false;
    for (size_t i = 0; i + 1 < _fault_injection_point.size(); ++i) {
        const char armed = _fault_injection_point[i].load(
            std::memory_order_relaxed);
        const char expected = point[i];
        if (armed != expected) return false;
        if (expected == '\0') break;
    }
    // One-shot: clear before set_fault so a nested check cannot re-enter.
    _fault_injection_armed.store(false, std::memory_order_release);
    _fault_injection_trip_count.fetch_add(1, std::memory_order_relaxed);
    char code[96];
    std::snprintf(code, sizeof(code), "fault_injected:%s", point);
    set_fault(code);
    return true;
}

std::FILE *pk_sim_trace_file() { return sim_day_trace_file(); }

} // namespace pk

#pragma once
#include "runtime_command_admission.h"
#include "runtime_pod_protocol.h"
#include "native_simulation_host_status.h"
#include "runtime_worker_timing.h"
#include "runtime_thread_retirement.h"
#include "runtime_authority_control.h"
#include "runtime_execution_context.h"
#include "runtime_day_waterfall.h"
#include "runtime_day_tail.h"
#include "runtime_player_confirmation.h"
#include "runtime_published_view.h"
#include "runtime_country_pod.h"
#include "country_core.h"
#include "runtime_domain_pod.h"
#include "runtime_authoritative_domains.h"
#include "runtime_climate_authority.h"
#include "runtime_climate_trace.h"
#include "runtime_climate_parity.h"
#include "runtime_domain_authorities.h"
#include "runtime_events_authority.h"
#include "runtime_modifier_pod.h"
#include "runtime_effect_pod.h"
#include "runtime_ideology_pod.h"
#include "runtime_economy_pod.h"
#include "economy_graph_kernels.h"
#include "annual_development_ledger.h"
#include "economy_host_port.h"
#include "country_host_port.h"
#include <array>
#include <atomic>
#include <cstddef>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <memory>
#include <map>
#include <deque>
#include <unordered_map>
#include <unordered_set>
#include <vector>
namespace pk {

struct VisionResearchState;
struct RuntimeGoldenSnapshot;
struct MilitaryCommandBatch;
struct RuntimeEconomyBoundaryRequest;
struct RuntimeEraRewardRequest;
struct RuntimeEraAdvancement;
struct RuntimeEraAdvancementView;
class NativeMilitaryRuntime;
class NativeEconomyRuntime;
class ModifierRuntime;
class EffectRuntime;
class CountryAiRuntime;
class NativeSimulationHost final : public EconomyHostPort, public CountryHostPort {
public:
    explicit NativeSimulationHost(uint64_t previous_country_session_epoch = 1);
    ~NativeSimulationHost();
    bool has_started_once() const noexcept { return _has_started_once.load(std::memory_order_acquire); }
    NativeSimulationHost(const NativeSimulationHost &) = delete;
    NativeSimulationHost &operator=(const NativeSimulationHost &) = delete;
    std::unique_ptr<NativeSimulationHost> make_new_world_host(std::string &error) const;
    // Hot-path gates need only these atomics. Do not construct the diagnostic
    // report (timers, transport queues and domain snapshots) to read a grant.
    using ControlState = RuntimeControlState;
    ControlState control_state() const;
    godot::Dictionary submit_player_confirmation(RuntimePlayerConfirmationRequest request);

    // FAULTED describes a business failure, not thread completion. The token
    // is published by the worker wrapper after all worker_main locals unwind.
    bool execution_has_stopped() const;

    bool configure_annual_development(uint64_t handle, int64_t length, int64_t day,
        const AnnualDevelopmentProfile &profile, const AnnualEconomyFacts &baseline,
        const AnnualCountryFacts &country, std::string &error);
    bool annual_development_enabled() const override { return _annual_enabled.load(std::memory_order_acquire); }
    bool annual_worker_managed() const;
    uint64_t annual_country_handle() const override { return _annual_country.load(std::memory_order_acquire); }
    void publish_annual_economy(const AnnualEconomyFacts &facts) override;
    void commit_annual_day(int64_t day, const AnnualCountryFacts &country, uint64_t draws);
    void commit_annual_worker_day(int64_t day);
    std::shared_ptr<const RuntimeFiscalDisplay> capture_economy_display(
        int64_t day, int64_t year_length, RuntimeDayTail &tail,
        const RuntimeDayTail *previous) const;
    void queue_annual_worker_reward(int64_t day);
    void settle_annual_worker_reward(const RuntimeIdeologyPodSnapshot &snapshot);
    bool annual_pending_reward(AnnualDevelopmentReport &out) const;
    void settle_annual_reward(uint64_t sequence);
    void annual_status(uint64_t &revision, int64_t &last_day, uint64_t &ready,
                       bool &reward_pending, size_t &count) const;
    bool annual_report(uint64_t id, AnnualDevelopmentReport &out) const;
    std::vector<AnnualDevelopmentReport> annual_history(uint32_t offset, uint32_t limit) const;
    const char *mark_annual_presented(uint64_t id);
    std::vector<uint8_t> encode_annual_save() const;
    bool restore_annual_save(const uint8_t *bytes, size_t size, std::string &error);

    // `requested_authority_mask` names the domains this worker is asked to own
    // in ACTIVE. It must be a subset of implemented_domain_mask(); requesting a
    // domain with no POD handler is rejected. The default asks for everything,
    // which is the pre-per-domain behaviour.
    bool start(RuntimeSimulationMode mode, bool graph_coverage_complete,
               int64_t initial_day, double speed_days_per_second, bool paused,
               uint32_t requested_authority_mask = RUNTIME_ALL_DOMAIN_MASK);
    // Compatibility overload for existing callers. A boolean coverage hint
    // is always an ACTIVE request; it never proves authority by itself.
    bool start(bool graph_coverage_complete, int64_t initial_day,
               double speed_days_per_second, bool paused) {
        return start(RuntimeSimulationMode::ACTIVE, graph_coverage_complete,
                     initial_day, speed_days_per_second, paused);
    }
    void request_stop();
    bool try_stop_at_day_boundary();
    void join_for_destruction();
    void set_clock(bool paused, double speed_days_per_second);
    void set_interactive(bool interactive);
    // ===== native_daily_inline（单线程内联日） =====
    //
    // 打开后由调用线程执行同一份 RuntimeDayPlan，并在重试间服务 peer。
    //
    // 关掉时行为与之前逐字节相同：`start()` 照旧 spawn worker，`run_inline_day()`
    // 直接拒绝。桌面端默认关闭。
    void set_inline_daily_mode(bool enabled) noexcept {
        _inline_daily_mode.store(enabled, std::memory_order_release);
    }
    bool inline_daily_mode() const noexcept {
        return _inline_daily_mode.load(std::memory_order_acquire);
    }
    bool inline_day_pending() const noexcept {
        return _inline_day_pending.load(std::memory_order_acquire);
    }
    // 一次内联日尝试的结果。只有 committed=true 表示这一天真的提交并发布了；
    // continuation_pending=true 表示屏障缺 peer 结果（调用方应在同一线程上泵一轮
    // peer 后重试同一天），false 且未提交表示硬失败，重试无用。
    using InlineDayOutcome = RuntimeInlineDayOutcome;
    // 在调用线程上同步执行一天。不做 CV 等待、不 spawn 线程、不设 peer-stall 超时。
    InlineDayOutcome run_inline_day();
    // 内联日单日墙钟预算（微秒，0 = 不设预算）。默认 30000，可用
    // PK_INLINE_DAY_BUDGET_MS 覆盖。execute_day_plan 用它做 stage 之间的看门狗，
    // run_native_daily_inline_day 用它给整次重试一个总上限。
    static int64_t inline_day_budget_us();
    // Measurement mode: on a Climate parity mismatch, adopt the production
    // reference for that day instead of discarding the plan. It never makes the
    // worker authoritative; it only stops the first divergent day from blocking
    // every later day, so a multi-day divergence matrix becomes measurable.
    void set_climate_parity_forcing(bool enabled) {
        _climate_parity_forcing.store(enabled, std::memory_order_release);
    }
    bool climate_parity_forcing() const {
        return _climate_parity_forcing.load(std::memory_order_acquire);
    }
    // Ideology parity reference capture. OFF by default and gated separately
    // from `climate_parity_forcing`: publishing a reference exports and hashes a
    // whole `RuntimeIdeologyPodSnapshot` every day, and a production session
    // must pay nothing for a diagnostic it is not running (03 idle-zero-cost).
    // Only a parity harness turns this on.
    void set_ideology_parity_enabled(bool enabled) {
        _ideology_parity_enabled.store(enabled, std::memory_order_release);
    }
    bool ideology_parity_enabled() const {
        return _ideology_parity_enabled.load(std::memory_order_acquire);
    }
    bool publish_environment(RuntimeEnvironmentSnapshot &&snapshot,
                             std::string &error);
    bool initialize_world_environment(RuntimeEnvironmentSnapshot &&seed,
        const godot::Dictionary &config, std::string &error);
    int64_t request_runtime_calendar_day(int64_t date);
    // worker：ring 内仍有未评估输入（有活可干）。
    bool has_pending_climate_input() const;
    // 主线程 publish：ring 已满，需 wait 腾空位。
    bool environment_ring_full() const;
    // P1：主线程**预发布**器用的只读探测。`environment_ring_full()` 的取反，
    // 但语义上单独命名 —— 预发布器问的是"现在还能不能塞一帧"，而不是"是不是
    // 满了"。只读，不改变任何状态。
    bool environment_ring_has_capacity() const;
    // P1：worker 已提交日的**廉价**读数（一次 acquire load）。预发布器每帧都要
    // 问它一次，走 report() 会每帧复制一整个 RuntimeThreadReport（上千字段 +
    // 若干定长 char 数组），在浏览器主线程上就是白白烧掉的帧预算。
    int64_t committed_day_value() const noexcept {
        return _committed_day.load(std::memory_order_acquire);
    }
    // The only day publish_environment accepts under Climate authority: the day
    // after the last published frame. Every main-thread publisher starts here.
    int64_t next_environment_day() const noexcept {
        return _environment_day.load(std::memory_order_acquire) + 1;
    }
    // First day whose command inputs have not been frozen.
    int64_t command_seal_day() const noexcept;
    RuntimeCommandAdmission admit_command(int64_t &effective_day);
    godot::Array take_boundary_command_results(bool &colonization_quotes_ready);
    size_t environment_ring_pending() const;
    // Compose RUNTIME_DAY_STALL_* from live ring/peer/input state.
    uint32_t day_stall_reason_mask() const;
    // Worker parks: OR sticky peer bits and arm the peer-stall timeout clock.
    void note_day_stall(uint32_t bits, int64_t day);
    // 无声 park 的点名器。只写「哪个域 + 哪一行放弃的」，不参与任何调度判断。
    void note_day_park(uint32_t domain_mask, const char *reason);
    // Clear a subset of sticky stall bits. Prefer this over wiping every peer
    // bit — Country commit must not erase Economy fiscal/input stalls.
    void clear_day_stall_bits(uint32_t bits);
    void clear_day_stall_peer_bits();
    void log_slow_peer(int64_t day);
    // publish 描述这一天生产 Climate 各段的真实执行情况（跑没跑、用的什么输入），
    // 全部字段可选；见 RuntimeClimateReferencePublish。
    bool publish_climate_reference(
            int64_t day, uint64_t reference_state_hash, std::string &error,
            RuntimeClimateReferencePublish publish = {});
    // 最近一次成功 publish（诊断 / 物理派生）。worker 日计划请用
    // environment_input_for_plan()。
    std::shared_ptr<const RuntimeEnvironmentSnapshot> environment_snapshot() const;
    // FIFO 最旧未消费输入；空则退回 latest。
    std::shared_ptr<const RuntimeEnvironmentSnapshot>
    environment_input_for_plan() const;
    bool publish_country_snapshot(const RuntimeCountryPodSnapshot &snapshot);
    void publish_economy_reference(int64_t day, uint64_t generation,
                                   uint64_t state_hash) noexcept;
#include "native_simulation_host_economy_control.inc"
#include "native_simulation_host_owner_ports.inc"
#include "native_simulation_host_country_transport.inc"
#include "native_simulation_host_rules_transport.inc"
#include "native_simulation_host_publication.inc"
private:
#include "native_simulation_host_executor.h"

#include "native_simulation_host_day_state.inc"
#include "native_simulation_host_country_state.inc"
#include "native_simulation_host_save_and_display.inc"
#include "native_simulation_host_economy_state.inc"
#include "native_simulation_host_domain_state.inc"
};
} // namespace pk

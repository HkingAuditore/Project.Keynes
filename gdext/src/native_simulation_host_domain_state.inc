// Climate and remaining domain parity, publication and transport state.

    // Consolidated SHADOW domain runner diagnostics. These values describe a
    // worker-only plan/replay transaction and never unlock ACTIVE.
    std::atomic<uint32_t> _domain_authority_planned_mask{0};
    std::atomic<uint32_t> _domain_authority_committed_mask{0};
    std::atomic<uint32_t> _domain_authority_ack_count{0};
    std::atomic<uint64_t> _domain_authority_input_hash{0};
    std::atomic<uint64_t> _domain_authority_state_hash{0};
    std::atomic<double> _domain_authority_plan_ms{0.0};
    std::atomic<double> _domain_authority_replay_ms{0.0};
    std::array<std::atomic<char>, 64> _domain_authority_fallback_reason{};
    std::atomic<uint32_t> _domain_stage_fallback_count{0};
    std::array<std::atomic<char>, 64> _domain_stage_fallback_reason{};
    std::atomic<bool> _climate_pod_ready{false};
    std::atomic<bool> _country_pod_ready{false};
    std::array<std::atomic<char>, 64> _country_pod_fallback_reason{};
    std::atomic<double> _climate_pod_plan_ms{0.0};
    std::atomic<double> _climate_pod_replay_ms{0.0};
    std::atomic<uint64_t> _climate_pod_work_units{0};
    std::atomic<uint32_t> _climate_pod_changed_cells{0};
    // Per-stage worker cost, indexed by RuntimeClimateStage. Published as
    // independent relaxed atomics like the rest of the diagnostic scalars: the
    // reader is a diagnostic table, so a torn row across two stages is
    // acceptable, and a lock here would sit on the worker's day boundary.
    std::array<std::atomic<double>, static_cast<size_t>(
        pk_async_climate::CLIMATE_STAGE_SLOT_COUNT)> _climate_stage_ms{};
    std::array<std::atomic<uint64_t>, static_cast<size_t>(
        pk_async_climate::CLIMATE_STAGE_SLOT_COUNT)> _climate_stage_work{};
    std::atomic<uint64_t> _climate_pod_state_hash{0};
    std::atomic<uint64_t> _climate_pod_reference_hash{0};
    std::atomic<bool> _climate_pod_parity_compared{false};
    std::atomic<bool> _climate_pod_parity_matched{false};
    std::atomic<uint64_t> _climate_pod_parity_mismatch_count{0};
    std::array<std::atomic<char>, 64> _climate_pod_parity_reason{};
    std::atomic<int64_t> _climate_parity_day{-1};
    std::atomic<uint16_t> _climate_parity_stage{0};
    std::atomic<uint32_t> _climate_parity_cell{0};
    std::atomic<uint64_t> _climate_parity_input_generation{0};
    std::atomic<uint64_t> _climate_parity_base_generation{0};
    std::atomic<uint64_t> _climate_parity_trace_hash{0};
    std::array<std::atomic<char>, 48> _climate_parity_field{};
    std::array<std::atomic<char>, 24> _climate_parity_reference_bits{};
    std::array<std::atomic<char>, 24> _climate_parity_worker_bits{};
    // Cumulative per-field divergence, indexed by the canonical parity table.
    // The first-difference slots above name one field per day; a migration plan
    // needs to know how far *every* field is from parity, which is what this
    // accumulates. Fixed size so the worker loop never allocates.
    std::array<ClimateParityFieldAccumulator, RUNTIME_CLIMATE_PARITY_MAX_FIELDS>
        _climate_parity_field_stats{};
    std::atomic<bool> _climate_parity_forcing{false};
    std::atomic<bool> _ideology_parity_enabled{false};
    std::atomic<uint64_t> _climate_parity_forced_days{0};
    std::array<std::atomic<char>, 64> _climate_pod_fallback_reason{};
    // 1 << RuntimeClimateStage。见 RuntimeThreadReport::climate_production_stage_mask。
    std::atomic<int32_t> _climate_production_stage_mask{0};
    std::atomic<int32_t> _climate_worker_stage_mask{0};
    // B8-2：worker 自持 cyclone 的当日事实。见
    // RuntimeThreadReport::climate_cyclone_alive。
    std::atomic<int32_t> _climate_cyclone_alive{0};
    std::atomic<int32_t> _climate_cyclone_injected{0};
    std::atomic<int32_t> _climate_cyclone_replaced{0};
    std::atomic<int32_t> _climate_cyclone_decayed{0};
    std::atomic<int32_t> _climate_cyclone_touched{0};
    std::atomic<double> _time_debt_days{0.0};
    std::array<std::atomic<char>, 64> _fault_code{};
    std::array<std::atomic<char>, 48> _economy_yield_reason{};
    std::array<std::atomic<char>, 32> _economy_stage_name{};
    std::array<std::atomic<char>, 40> _economy_substage_name{};
    std::atomic<double> _economy_epoch_fiscal_ms{0.0};
    std::atomic<double> _economy_fiscal_settlement_ms{0.0};
    std::atomic<double> _economy_income_subsidy_ms{0.0};
    std::atomic<uint32_t> _economy_negative_tax_mask{0};
    std::atomic<uint32_t> _economy_active_tax_mask{0};
    std::atomic<uint32_t> _economy_attempt_slices{0};
    // Controllable one-shot fault injection. Empty / disarmed by default so
    // production paths never trip. Point names are stable ASCII tokens such as
    // "economy.plan.before" or "authority.switch.after".
    std::atomic<bool> _fault_injection_armed{false};
    std::atomic<uint64_t> _fault_injection_trip_count{0};
    std::array<std::atomic<char>, 64> _fault_injection_point{};
    std::atomic<uint64_t> _state_hash{1469598103934665603ull};
    RuntimeDomainPodPipeline _pod_pipeline;
    // Phase-C migration aggregate.  It is reset and owned exclusively by the
    // worker host; individual domains are enabled only after parity gates.
    RuntimeAuthoritativeDomainStores _authoritative_domains;
    RuntimeDomainAuthorityRunner _domain_authority_runner;
    RuntimeModifierPodAuthority _modifier_pod_authority;
    RuntimeModifierPodCatalog _modifier_pod_catalog;
    bool _modifier_pod_configured = false;
    // Effect command definition_key_hash → Modifier POD definition_id.
    std::unordered_map<uint64_t, int32_t> _modifier_definition_id_by_key_hash;
    RuntimeModifierSnapshotRing _modifier_snapshots;
    std::atomic<bool> _modifier_pod_ready{false};
    std::atomic<double> _modifier_pod_plan_ms{0.0};
    std::atomic<double> _modifier_pod_replay_ms{0.0};
    std::atomic<uint64_t> _modifier_pod_work_units{0};
    std::atomic<uint64_t> _modifier_pod_state_hash{0};
    std::atomic<uint64_t> _modifier_pod_snapshot_generation{0};
    std::atomic<uint32_t> _modifier_pod_ack_count{0};
    std::array<std::atomic<char>, 64> _modifier_pod_fallback_reason{};
    RuntimeEventsAuthority _events_authority;
    RuntimeEventsSnapshotRing _events_snapshots;
    std::atomic<bool> _events_pod_ready{false};
    std::atomic<double> _events_pod_plan_ms{0.0};
    std::atomic<double> _events_pod_replay_ms{0.0};
    std::atomic<uint64_t> _events_pod_state_hash{0};
    std::atomic<uint64_t> _events_pod_snapshot_generation{0};
    std::atomic<uint32_t> _events_pod_event_count{0};
    std::atomic<uint32_t> _events_pod_ack_count{0};
    std::atomic<uint64_t> _events_pod_drop_count{0};
    std::array<std::atomic<char>, 64> _events_pod_fallback_reason{};
    std::atomic<uint64_t> _events_pod_rejected_count{0};
    // ACTIVE 下硬失败（非包级拒绝）的日子；-1 表示最近一次 Events 已提交。
    std::atomic<int64_t> _events_failed_day{-1};
    // Events is a diagnostic sidecar. Keep a worker-local watermark so a
    // Climate input-barrier retry cannot advance its generation twice for the
    // same host day.
    int64_t _events_last_processed_day = -1;
    // Worker-only: ACTIVE economy facts become Events rows, and committed
    // Events rows become Trigger POD ingest commands.
    uint64_t _economy_fact_event_sequence = 0;
    int64_t _trigger_forwarded_event_id = 0;
    uint64_t _trigger_forward_sequence = 0;
    void forward_committed_events_to_trigger(int64_t day);
    RuntimeEffectPodAuthority _effect_pod_authority;
    RuntimeEffectPodCatalog _effect_pod_catalog;
    RuntimeEffectSnapshotRing _effect_snapshots;
    bool _effect_pod_configured = false;
    struct EffectPodMetricQueueItem {
        int64_t instance_id = 0;
        uint32_t generation = 0;
        int32_t metric_id = 0;
        int64_t revision = 0;
        int64_t value = 0;
    };
    // Upserts and retires share ONE arrival sequence. The drain replays them in
    // arrival order: an Effect soft-skip can leave "submit on day N" and
    // "retire on day N+1" sitting in the queue together, and draining either
    // deque wholesale would swap that pair into "retire, submit" -- which
    // silently resurrects the very instance the caller retired.
    struct EffectPodInstanceQueueItem {
        uint64_t sequence = 0;
        RuntimeEffectPodInstanceInput input;
    };
    struct EffectPodRemoveQueueItem {
        uint64_t sequence = 0;
        int64_t instance_id = 0;
        uint32_t generation = 0;
    };
    mutable std::mutex _effect_transport_mutex;
    // Guarded by `_effect_transport_mutex`.
    uint64_t _effect_transport_sequence = 0;
    std::deque<EffectPodInstanceQueueItem> _effect_instance_queue;
    std::deque<EffectPodMetricQueueItem> _effect_metric_queue;
    std::deque<EffectPodRemoveQueueItem> _effect_remove_queue;
    std::deque<RuntimeDomainIntent> _effect_intents;
    std::deque<RuntimeDomainAck> _effect_acks;
    // Day-local MODIFIER-targeted intents produced by the Effect stage for
    // Modifier E7. Cleared at the start of each Effect stage visit.
    std::vector<RuntimeDomainIntent> _effect_day_modifier_intents;
    std::vector<RuntimeDomainIntent> _effect_day_intents;
    bool _effect_day_stage_ok = false;
    std::atomic<bool> _effect_pod_ready{false};
    std::atomic<double> _effect_pod_plan_ms{0.0};
    std::atomic<double> _effect_pod_replay_ms{0.0};
    std::atomic<uint64_t> _effect_pod_state_hash{0};
    std::atomic<uint64_t> _effect_pod_snapshot_generation{0};
    std::atomic<uint32_t> _effect_pod_ack_count{0};
    std::atomic<uint32_t> _effect_pod_intent_count{0};
    std::atomic<uint32_t> _effect_pod_managed_intent_count{0};
    std::atomic<uint32_t> _effect_pod_unmanaged_intent_count{0};
    std::atomic<uint32_t> _effect_pod_program_intent_count{0};
    std::array<std::atomic<int32_t>,
        RUNTIME_EFFECT_INTENT_PROGRAM_REPORT_CAPACITY>
        _effect_pod_intent_program_ids{};
    std::atomic<uint32_t> _effect_pod_transaction_count{0};
    // Missing instances retire successfully; track absent and stale separately.
    std::atomic<uint64_t> _effect_retire_absent_count{0};
    std::atomic<uint64_t> _effect_retire_stale_count{0};
    std::array<std::atomic<char>, 64> _effect_pod_fallback_reason{};
    mutable std::mutex _ideology_transport_mutex;
    RuntimeIdeologyPodAuthority _ideology_pod_authority;
    RuntimeIdeologyPodCatalog _ideology_pod_catalog;
    bool _ideology_pod_configured = false;
#include "native_simulation_host_view_contracts.h"
    std::shared_ptr<const RuntimeIdeologyOpinionSnapshot> _ideology_opinion_snapshot;
    std::map<int64_t, std::shared_ptr<const RuntimeIdeologyOpinionSnapshot>>
        _ideology_reference_opinions;
    std::shared_ptr<const RuntimeIdeologyPodSnapshot> _ideology_snapshot;
    // G8 ACTIVE write-back boundary. The shared_ptr above stays for SHADOW
    // consumers; the ring is the immutable main-thread apply path.
    RuntimeIdeologySnapshotRing _ideology_snapshots;
    std::deque<RuntimeIdeologyPodCommand> _ideology_commands;
    std::deque<RuntimeDomainIntent> _ideology_intents;
    std::deque<RuntimeDomainAck> _ideology_acks;
    // Worker-thread only: Ideology transitions waiting for Modifier results.
    struct IdeologyModifierInflight {
        RuntimeDomainIntent intent;
        std::vector<RuntimeIdeologyPodModifierRow> rows;
        int32_t batch_index = -1;
        uint8_t submitted = 0;
    };
    std::vector<IdeologyModifierInflight> _ideology_modifier_inflight;
    std::vector<RuntimeIdeologyPodModifierRow> _ideology_loose_modifier_rows;
    std::vector<std::vector<RuntimeModifierPodCommand>> _ideology_day_modifier_batches;
    uint64_t _ideology_modifier_sequence = 1;
    std::atomic<bool> _ideology_pod_ready{false};
    std::atomic<double> _ideology_pod_plan_ms{0.0};
    std::atomic<double> _ideology_pod_replay_ms{0.0};
    std::atomic<uint64_t> _ideology_pod_state_hash{0};
    std::atomic<uint64_t> _ideology_pod_snapshot_generation{0};
    std::atomic<uint32_t> _ideology_pod_pending_transition_count{0};
    std::atomic<uint32_t> _ideology_pod_intent_count{0};
    std::atomic<uint32_t> _ideology_opinion_wait_days{0};
    std::array<std::atomic<char>, 64> _ideology_pod_fallback_reason{};
    // H7/H8 Trigger transport. The POD authority itself lives in
    // _domain_authority_runner (shared with the SHADOW probe); these are the
    // ACTIVE-only boundaries around it.
    mutable std::mutex _trigger_transport_mutex;
    RuntimeTriggerSnapshotRing _trigger_snapshots;
    std::deque<RuntimeTriggerEffectIntent> _trigger_intents;
    std::deque<RuntimeDomainAck> _trigger_acks;
    int64_t _trigger_published_intent_id = 0;
    std::atomic<bool> _trigger_pod_ready{false};
    std::atomic<double> _trigger_pod_plan_ms{0.0};
    std::atomic<double> _trigger_pod_replay_ms{0.0};
    std::atomic<uint64_t> _trigger_pod_state_hash{0};
    std::atomic<uint64_t> _trigger_pod_snapshot_generation{0};
    std::atomic<uint32_t> _trigger_pod_intent_count{0};
    std::atomic<uint32_t> _trigger_pod_ack_count{0};
    std::array<std::atomic<char>, 64> _trigger_pod_fallback_reason{};
    RuntimeClimateAuthority _climate_authority;
    RuntimeClimateWritebackRing _climate_writeback;
    std::atomic<uint64_t> _climate_writeback_sequence{0};
    // Last Climate day handed to the main thread. Guards against republishing
    // an unchanged store on days the worker clock ran ahead of the environment.
    std::atomic<int64_t> _climate_writeback_last_day{-1};
    // Main-thread-readable mirror of the Climate store's committed day. Under
    // authority this, not `_committed_day`, is the watermark an incoming
    // environment must clear: the worker clock advances on its own and would
    // otherwise reject the very input Climate is waiting for.
    std::atomic<int64_t> _climate_committed_day{-1};
    std::atomic<uint64_t> _climate_committed_input_generation{0};
    // 主线程 writeback 已应用的 input_generation；诊断用，不再驱动 pending 判定。
    std::atomic<uint64_t> _climate_writeback_input_generation{0};
    // 生成/恢复快照是已存在的基线，不是待执行的日输入。
    std::atomic<int64_t> _climate_bootstrap_day{0};
    mutable std::mutex _environment_publish_mutex;
    // Reused worker-local output arenas; no per-day heap growth in the hot
    // loop. They are never exposed to Godot or another thread.
    std::vector<RuntimeCommandReceipt> _pod_receipts;

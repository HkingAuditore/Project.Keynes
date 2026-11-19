#pragma once

#include "country_core.h"
#include "runtime_pod_protocol.h"

namespace pk {

struct RuntimeControlState {
    RuntimeWorkerState state = RuntimeWorkerState::STOPPED;
    RuntimeSimulationMode mode = RuntimeSimulationMode::OFF;
    bool authority_ready = false;
    bool interactive = false;
    uint32_t authoritative_domain_mask = 0;
    uint32_t requested_authority_mask = 0;
    int64_t committed_day = -1;
};

struct RuntimeInlineDayOutcome {
    bool committed = false;
    bool continuation_pending = false;
    bool country_peer_progress = false;
    int64_t from_day = -1;
    int64_t day = -1;
    int64_t environment_day = -1;
    uint32_t completed_domain_mask = 0;
    uint32_t completed_stage_count = 0;
    uint32_t stage_count = 0;
    uint32_t dirty_families = 0;
    uint64_t work_units = 0;
    char reason[64]{};
    // ===== 分域/分阶段计时（native_daily_inline 诊断）=====
    //
    // 只覆盖"一次尝试"（一次 run_inline_day 调用）；重试由调用方按域累加。
    // 下标与 runtime_domain_stage_order() 同序，键名用
    // runtime_domain_stage_key()。
    //
    // 注意 stage_ms[CLIMATE] 装的是 Climate 内核的真实耗时，而内核在 12 域
    // 循环之前就跑完了（见 execute_day_plan 的 PRE_SETUP 段），所以它是
    // pre_stage_ms 的一部分。恒等式近似为：
    //   elapsed_ms ≈ plan_build_ms + pre_stage_ms
    //              + (sum(stage_ms) - stage_ms[climate])
    //              + commit_tail_ms
    double stage_ms[RUNTIME_DOMAIN_STAGE_COUNT]{};
    double pre_stage_ms = 0.0;   // stage 循环之前（含 Climate 内核）
    double climate_ms = 0.0;     // pre_stage_ms 中属于 Climate 内核的部分
    double plan_build_ms = 0.0;  // build_day_plan
    double commit_tail_ms = 0.0; // 日尾：Climate writeback + publish + 读视图
    // 单日墙钟预算看门狗：超预算时不再继续推进 stage，而是带着
    // budget_exceeded 收工，让调用方看到一次"有界的失败"而不是挂死。
    bool budget_exceeded = false;
    // 本线程这次是否真的把并行执行器切成了串行（浏览器内置日必须为 true）。
    uint32_t executor_serial_only = 0;
};

struct RuntimeCountryWorkerProtocolStatus {
    uint32_t protocol_version = COUNTRY_PEER_PROTOCOL_VERSION;
    bool configured = false;
    bool plan_active = false;
    bool waiting_for_peer = false;
    uint32_t pending_intents = 0;
    uint32_t queued_intents = 0;
    uint32_t result_count = 0;
    uint32_t rejected_results = 0;
    uint32_t rejected_intents = 0;
    bool has_unreported_rejection = false;
    int64_t retry_day = -1;
    uint64_t rejected_request_id = 0;
    uint64_t session_epoch = 0;
    uint64_t country_generation = 0;
    int64_t day = -1;
    uint32_t continuation_index = 0;
    uint64_t boundary_id = 0;
    uint64_t last_admitted_submit_order = 0;
    uint64_t expected_base_generation = 0;
    uint64_t catalog_hash = 0;
    char last_reason[64]{};
};

} // namespace pk

#pragma once

// Godot-free Economy graph stage contracts, BUILDING_PLAN kernel boundary, and
// StageOps dispatch. Worker TUs must not include economy_runtime.h from here.

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace pk {

enum class RuntimeEconomyGraphStage : uint32_t {
    BUILDING_PLAN = 0,
    TRADE_SETTLE = 1,
    LEDGER_APPLY = 2,
    BUILDING_EMPLOYMENT = 3,
    BUILDING_PRODUCTION = 4,
    HOUSEHOLD_MARKET = 5,
    GOVERNMENT_RESEARCH_PROCUREMENT = 6,
    TRADE_DISPATCH = 7,
    STRUCTURAL_COMMIT = 8,
    BUILDING_COMMIT = 9,
    FAMILY_COMMIT = 10,
    PERSON_COMMIT = 11,
    AGGREGATE_PUBLISH = 12,
    COUNT = 13,
};

constexpr size_t RUNTIME_ECONOMY_GRAPH_STAGE_COUNT =
    static_cast<size_t>(RuntimeEconomyGraphStage::COUNT);

constexpr uint32_t runtime_economy_graph_stage_bit(
        RuntimeEconomyGraphStage stage) noexcept {
    return 1u << static_cast<uint32_t>(stage);
}

constexpr uint32_t RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK =
    (1u << RUNTIME_ECONOMY_GRAPH_STAGE_COUNT) - 1u;

inline const char *runtime_economy_graph_stage_name(
        RuntimeEconomyGraphStage stage) noexcept {
    switch (stage) {
    case RuntimeEconomyGraphStage::BUILDING_PLAN: return "BUILDING_PLAN";
    case RuntimeEconomyGraphStage::TRADE_SETTLE: return "TRADE_SETTLE";
    case RuntimeEconomyGraphStage::LEDGER_APPLY: return "LEDGER_APPLY";
    case RuntimeEconomyGraphStage::BUILDING_EMPLOYMENT:
        return "BUILDING_EMPLOYMENT";
    case RuntimeEconomyGraphStage::BUILDING_PRODUCTION:
        return "BUILDING_PRODUCTION";
    case RuntimeEconomyGraphStage::HOUSEHOLD_MARKET: return "HOUSEHOLD_MARKET";
    case RuntimeEconomyGraphStage::GOVERNMENT_RESEARCH_PROCUREMENT:
        return "GOVERNMENT_RESEARCH_PROCUREMENT";
    case RuntimeEconomyGraphStage::TRADE_DISPATCH: return "TRADE_DISPATCH";
    case RuntimeEconomyGraphStage::STRUCTURAL_COMMIT: return "STRUCTURAL_COMMIT";
    case RuntimeEconomyGraphStage::BUILDING_COMMIT: return "BUILDING_COMMIT";
    case RuntimeEconomyGraphStage::FAMILY_COMMIT: return "FAMILY_COMMIT";
    case RuntimeEconomyGraphStage::PERSON_COMMIT: return "PERSON_COMMIT";
    case RuntimeEconomyGraphStage::AGGREGATE_PUBLISH: return "AGGREGATE_PUBLISH";
    case RuntimeEconomyGraphStage::COUNT: break;
    }
    return "UNKNOWN";
}

struct RuntimeEconomyEpochInput {
    int64_t sample_day = -1;
    uint64_t session_epoch = 0;
    uint64_t economy_generation = 0;
    uint64_t input_generation = 0;
    uint64_t country_generation = 0;
    uint64_t catalog_hash = 0;
    uint64_t policy_hash = 0;
    uint64_t environment_shape_hash = 0;
    uint32_t cell_count = 0;
    int32_t market_cycle_days = 0;
    int32_t production_cycle_days = 0;
    int32_t investment_cycle_days = 0;
    bool valid = false;
};

struct EconomyStageCursor {
    uint32_t stage_index = 0;
    uint32_t cell_cursor = 0;
    uint32_t group_cursor = 0;
    uint32_t command_cursor = 0;
    uint32_t slice_index = 0;
    uint8_t waiting_for_peer = 0;
    uint8_t evaluate_phase = 0;
};

struct EconomyStageResult {
    bool ok = true;
    bool fatal = false;
    uint64_t work_units = 0;
    uint64_t state_hash = 0;
    int64_t population_error = 0;
    int64_t money_error = 0;
    int64_t goods_error = 0;
    char error[128]{};
    char fatal_reason[64]{};

    void reset() noexcept { *this = EconomyStageResult{}; }
};

struct EconomySoAView {
    uint32_t cell_count = 0;
    uint32_t country_count = 0;
    uint32_t good_count = 0;
    int32_t *building_cell_offsets = nullptr;
    size_t building_cell_offsets_count = 0;
    int32_t *building_active_cells = nullptr;
    size_t building_active_cells_count = 0;
    int32_t *epoch_plan_cells = nullptr;
    size_t epoch_plan_cells_count = 0;
    uint8_t *survival_food_good_mask = nullptr;
    uint8_t *survival_clothing_good_mask = nullptr;
    size_t survival_mask_count = 0;
    int64_t *population_by_cell = nullptr;
    int64_t *treasury_by_country = nullptr;
    uint64_t generation = 0;
    int64_t sample_day = -1;
    int64_t committed_day = -1;
    void *runtime_hook = nullptr;
};

class EconomyGraphStageOps {
public:
    virtual ~EconomyGraphStageOps() = default;
    virtual bool bind_view(EconomySoAView &view, std::string &error) = 0;
    virtual bool run_stage(RuntimeEconomyGraphStage stage,
                           EconomyStageCursor &cursor,
                           const RuntimeEconomyEpochInput &input,
                           EconomyStageResult &result,
                           std::string &error) = 0;
    virtual uint64_t state_hash() const = 0;
    virtual bool capture_probe(std::vector<uint8_t> &bytes,
                               std::string &error) const = 0;
    virtual bool restore_probe(const uint8_t *bytes, size_t size,
                               std::string &error) = 0;
};

bool economy_kernel_run_stage(EconomyGraphStageOps &ops,
                              RuntimeEconomyGraphStage stage,
                              EconomyStageCursor &cursor,
                              const RuntimeEconomyEpochInput &input,
                              EconomyStageResult &result,
                              std::string &error);

// Named Godot-free kernel entry points. When view.runtime_hook is null these
// keep the self_test boundary stub (work=cell_count, hash=generation). When a
// NativeEconomyRuntime hook is bound they call economy_dispatch_mutate_stage.
bool economy_kernel_trade_settle(EconomySoAView &view, EconomyStageCursor &cursor,
                                 const RuntimeEconomyEpochInput &input,
                                 EconomyStageResult &result, std::string &error);
bool economy_kernel_ledger(EconomySoAView &view, EconomyStageCursor &cursor,
                           const RuntimeEconomyEpochInput &input,
                           EconomyStageResult &result, std::string &error);
bool economy_kernel_building_employment(EconomySoAView &view,
                                        EconomyStageCursor &cursor,
                                        const RuntimeEconomyEpochInput &input,
                                        EconomyStageResult &result,
                                        std::string &error);
bool economy_kernel_building_production(EconomySoAView &view,
                                        EconomyStageCursor &cursor,
                                        const RuntimeEconomyEpochInput &input,
                                        EconomyStageResult &result,
                                        std::string &error);
bool economy_kernel_building_commit(EconomySoAView &view,
                                    EconomyStageCursor &cursor,
                                    const RuntimeEconomyEpochInput &input,
                                    EconomyStageResult &result,
                                    std::string &error);
bool economy_kernel_household_market(EconomySoAView &view,
                                     EconomyStageCursor &cursor,
                                     const RuntimeEconomyEpochInput &input,
                                     EconomyStageResult &result,
                                     std::string &error);
bool economy_kernel_research(EconomySoAView &view, EconomyStageCursor &cursor,
                             const RuntimeEconomyEpochInput &input,
                             EconomyStageResult &result, std::string &error);
bool economy_kernel_trade_dispatch(EconomySoAView &view,
                                   EconomyStageCursor &cursor,
                                   const RuntimeEconomyEpochInput &input,
                                   EconomyStageResult &result,
                                   std::string &error);
bool economy_kernel_structural(EconomySoAView &view, EconomyStageCursor &cursor,
                               const RuntimeEconomyEpochInput &input,
                               EconomyStageResult &result, std::string &error);
bool economy_kernel_family_person(EconomySoAView &view,
                                  EconomyStageCursor &cursor,
                                  const RuntimeEconomyEpochInput &input,
                                  EconomyStageResult &result,
                                  std::string &error);
bool economy_kernel_publish(EconomySoAView &view, EconomyStageCursor &cursor,
                            const RuntimeEconomyEpochInput &input,
                            EconomyStageResult &result, std::string &error);

// Shared boundary stub used by named kernel TUs when runtime_hook is null
// (self_test). Live mutation with a bound hook goes through dispatch.
inline bool economy_kernel_stage_boundary_stub(
        EconomySoAView &view, EconomyStageCursor & /*cursor*/,
        const RuntimeEconomyEpochInput &input, EconomyStageResult &result,
        std::string &error) {
    result.reset();
    error.clear();
    result.work_units = input.cell_count;
    result.state_hash = view.generation;
    if (view.runtime_hook != nullptr) {
        result.state_hash = view.generation;
    }
    result.ok = true;
    return true;
}

uint32_t economy_kernel_bound_stage_mask() noexcept;

struct EconomyBuildingPlanResult {
    bool ok = true;
    int64_t saturation_count = 0;
    int64_t merchant_credit_budget = 0;
    int64_t merchant_credit_committed = 0;
    int64_t recovery_candidates = 0;
    int64_t recovery_approved = 0;
    int64_t loss_suspended_building_groups = 0;
    int64_t unprofitable_building_groups = 0;
    int64_t utilization_sum_q16 = 0;
    double worker_ms = 0.0;
    char error[128]{};

    void reset() noexcept { *this = EconomyBuildingPlanResult{}; }
};

class EconomyBuildingPlanExecutor {
public:
    virtual ~EconomyBuildingPlanExecutor() = default;
    virtual bool execute(int32_t active_begin, int32_t active_end,
                         const int32_t *cells_override, int32_t cells_count,
                         EconomyBuildingPlanResult &result,
                         std::string &error) = 0;
};

bool economy_kernel_prepare_building_plan(
        EconomyBuildingPlanExecutor &executor, int32_t active_begin,
        int32_t active_end, const int32_t *cells_override, int32_t cells_count,
        EconomyBuildingPlanResult &result, std::string &error);

bool economy_graph_kernels_self_test(std::string &error);

} // namespace pk

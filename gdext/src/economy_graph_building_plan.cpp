#include "economy_graph_kernels.h"

#include <cstring>

namespace pk {
namespace {

void copy_error(char *dst, size_t capacity, const std::string &value) {
    if (capacity == 0) return;
    const size_t n = value.size() < capacity - 1u ? value.size() : capacity - 1u;
    if (n > 0) std::memcpy(dst, value.data(), n);
    dst[n] = '\0';
}

void copy_cstr(char *dst, size_t capacity, const char *value) {
    if (capacity == 0) return;
    size_t i = 0;
    if (value != nullptr) {
        for (; i + 1 < capacity && value[i] != '\0'; ++i) dst[i] = value[i];
    }
    dst[i] = '\0';
}

class EconomyBuildingPlanProbeExecutor final : public EconomyBuildingPlanExecutor {
public:
    bool execute(int32_t active_begin, int32_t active_end,
                 const int32_t *cells_override, int32_t cells_count,
                 EconomyBuildingPlanResult &result,
                 std::string &error) override {
        result.reset();
        error.clear();
        if (active_begin < 0 || active_end < active_begin) {
            error = "economy_building_plan_probe_range_invalid";
            copy_error(result.error, sizeof(result.error), error);
            result.ok = false;
            return false;
        }
        const int32_t span = active_end - active_begin;
        if (cells_override != nullptr && cells_count < span) {
            error = "economy_building_plan_probe_cells_short";
            copy_error(result.error, sizeof(result.error), error);
            result.ok = false;
            return false;
        }
        result.saturation_count = 0;
        result.ok = true;
        (void)cells_override;
        return true;
    }
};

constexpr uint64_t FNV_OFFSET = 1469598103934665603ull;
constexpr uint64_t FNV_PRIME = 1099511628211ull;

uint64_t mix(uint64_t h, uint64_t v) noexcept {
    h ^= v;
    h *= FNV_PRIME;
    return h;
}

} // namespace

bool economy_kernel_prepare_building_plan(
        EconomyBuildingPlanExecutor &executor, int32_t active_begin,
        int32_t active_end, const int32_t *cells_override, int32_t cells_count,
        EconomyBuildingPlanResult &result, std::string &error) {
    result.reset();
    error.clear();
    if (!executor.execute(active_begin, active_end, cells_override, cells_count,
                          result, error)) {
        if (error.empty()) error = "economy_building_plan_kernel_failed";
        if (result.error[0] == '\0')
            copy_error(result.error, sizeof(result.error), error);
        result.ok = false;
        return false;
    }
    result.ok = true;
    return true;
}

uint32_t economy_kernel_bound_stage_mask() noexcept {
    // Phase 2: all 13 stages are bound through EconomyGraphStageOps (live or
    // probe). Placeholder hash-only bodies are retired once ops is attached.
    return RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK;
}

bool economy_kernel_run_stage(EconomyGraphStageOps &ops,
                              RuntimeEconomyGraphStage stage,
                              EconomyStageCursor &cursor,
                              const RuntimeEconomyEpochInput &input,
                              EconomyStageResult &result,
                              std::string &error) {
    result.reset();
    error.clear();
    if (!input.valid || input.cell_count == 0) {
        error = "economy_kernel_stage_input_invalid";
        copy_cstr(result.error, sizeof(result.error), error.c_str());
        result.ok = false;
        return false;
    }
    if (static_cast<uint32_t>(stage) >= RUNTIME_ECONOMY_GRAPH_STAGE_COUNT) {
        error = "economy_kernel_stage_oob";
        copy_cstr(result.error, sizeof(result.error), error.c_str());
        result.ok = false;
        return false;
    }
    if (!ops.run_stage(stage, cursor, input, result, error)) {
        if (error.empty()) error = "economy_kernel_stage_failed";
        if (result.error[0] == '\0')
            copy_cstr(result.error, sizeof(result.error), error.c_str());
        result.ok = false;
        return false;
    }
    if (result.state_hash == 0) {
        result.state_hash = mix(FNV_OFFSET, static_cast<uint64_t>(stage));
        result.state_hash = mix(result.state_hash, input.input_generation);
        result.state_hash = mix(result.state_hash, result.work_units);
        result.state_hash = mix(result.state_hash, ops.state_hash());
    }
    result.ok = true;
    return true;
}

bool economy_graph_kernels_self_test(std::string &error) {
    error.clear();
    if (RUNTIME_ECONOMY_GRAPH_STAGE_COUNT != 13u ||
        RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK != 0x1FFFu) {
        error = "economy_graph_stage_count_mismatch";
        return false;
    }
    static const RuntimeEconomyGraphStage kOrder[] = {
        RuntimeEconomyGraphStage::BUILDING_PLAN,
        RuntimeEconomyGraphStage::TRADE_SETTLE,
        RuntimeEconomyGraphStage::LEDGER_APPLY,
        RuntimeEconomyGraphStage::BUILDING_EMPLOYMENT,
        RuntimeEconomyGraphStage::BUILDING_PRODUCTION,
        RuntimeEconomyGraphStage::HOUSEHOLD_MARKET,
        RuntimeEconomyGraphStage::GOVERNMENT_RESEARCH_PROCUREMENT,
        RuntimeEconomyGraphStage::TRADE_DISPATCH,
        RuntimeEconomyGraphStage::STRUCTURAL_COMMIT,
        RuntimeEconomyGraphStage::BUILDING_COMMIT,
        RuntimeEconomyGraphStage::FAMILY_COMMIT,
        RuntimeEconomyGraphStage::PERSON_COMMIT,
        RuntimeEconomyGraphStage::AGGREGATE_PUBLISH,
    };
    uint32_t mask = 0;
    for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
        if (static_cast<uint32_t>(kOrder[i]) != static_cast<uint32_t>(i)) {
            error = "economy_graph_stage_order_mismatch";
            return false;
        }
        const char *name = runtime_economy_graph_stage_name(kOrder[i]);
        if (name == nullptr || name[0] == '\0' ||
            std::strcmp(name, "UNKNOWN") == 0) {
            error = "economy_graph_stage_name_missing";
            return false;
        }
        mask |= runtime_economy_graph_stage_bit(kOrder[i]);
    }
    if (mask != RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK ||
        economy_kernel_bound_stage_mask() != RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK) {
        error = "economy_graph_stage_mask_incomplete";
        return false;
    }

    EconomyBuildingPlanProbeExecutor probe;
    EconomyBuildingPlanResult result;
    std::string kernel_error;
    const int32_t cells[2] = {0, 1};
    if (!economy_kernel_prepare_building_plan(probe, 0, 2, cells, 2, result,
                                              kernel_error) ||
        !result.ok || kernel_error.size() != 0) {
        error = kernel_error.empty()
            ? "economy_building_plan_probe_failed" : kernel_error;
        return false;
    }
    if (economy_kernel_prepare_building_plan(probe, 2, 1, nullptr, 0, result,
                                             kernel_error)) {
        error = "economy_building_plan_probe_should_reject_inverted_range";
        return false;
    }

    // Named kernel stubs must admit an empty SoA view and report cell_count work.
    EconomySoAView empty_view;
    empty_view.generation = 42;
    RuntimeEconomyEpochInput stub_input;
    stub_input.cell_count = 7;
    stub_input.valid = true;
    EconomyStageCursor stub_cursor;
    EconomyStageResult stub_result;
    std::string stub_error;
    auto expect_stub = [&](bool (*fn)(EconomySoAView &, EconomyStageCursor &,
                                      const RuntimeEconomyEpochInput &,
                                      EconomyStageResult &, std::string &),
                           const char *label) -> bool {
        stub_result.reset();
        stub_error.clear();
        if (!fn(empty_view, stub_cursor, stub_input, stub_result, stub_error) ||
            !stub_result.ok || stub_result.work_units != stub_input.cell_count ||
            stub_result.state_hash != empty_view.generation) {
            error = label;
            return false;
        }
        return true;
    };
    if (!expect_stub(economy_kernel_trade_settle,
                     "economy_kernel_trade_settle_stub_failed") ||
        !expect_stub(economy_kernel_ledger,
                     "economy_kernel_ledger_stub_failed") ||
        !expect_stub(economy_kernel_building_employment,
                     "economy_kernel_building_employment_stub_failed") ||
        !expect_stub(economy_kernel_building_production,
                     "economy_kernel_building_production_stub_failed") ||
        !expect_stub(economy_kernel_building_commit,
                     "economy_kernel_building_commit_stub_failed") ||
        !expect_stub(economy_kernel_household_market,
                     "economy_kernel_household_market_stub_failed") ||
        !expect_stub(economy_kernel_research,
                     "economy_kernel_research_stub_failed") ||
        !expect_stub(economy_kernel_trade_dispatch,
                     "economy_kernel_trade_dispatch_stub_failed") ||
        !expect_stub(economy_kernel_structural,
                     "economy_kernel_structural_stub_failed") ||
        !expect_stub(economy_kernel_family_person,
                     "economy_kernel_family_person_stub_failed") ||
        !expect_stub(economy_kernel_publish,
                     "economy_kernel_publish_stub_failed")) {
        return false;
    }
    return true;
}

} // namespace pk

#include "economy_graph_kernels.h"
#include "economy_graph_stage_dispatch.h"

namespace pk {

bool economy_kernel_family_person(EconomySoAView &view,
                                  EconomyStageCursor &cursor,
                                  const RuntimeEconomyEpochInput &input,
                                  EconomyStageResult &result,
                                  std::string &error) {
    if (view.runtime_hook == nullptr)
        return economy_kernel_stage_boundary_stub(view, cursor, input, result,
                                                  error);
    // evaluate_phase 0 → FAMILY only; 1 → PERSON only; else both sequentially.
    if (cursor.evaluate_phase == 0) {
        return economy_dispatch_mutate_stage(
            view, RuntimeEconomyGraphStage::FAMILY_COMMIT, cursor, input,
            result, error);
    }
    if (cursor.evaluate_phase == 1) {
        return economy_dispatch_mutate_stage(
            view, RuntimeEconomyGraphStage::PERSON_COMMIT, cursor, input,
            result, error);
    }
    if (!economy_dispatch_mutate_stage(
            view, RuntimeEconomyGraphStage::FAMILY_COMMIT, cursor, input,
            result, error)) {
        return false;
    }
    return economy_dispatch_mutate_stage(
        view, RuntimeEconomyGraphStage::PERSON_COMMIT, cursor, input, result,
        error);
}

} // namespace pk

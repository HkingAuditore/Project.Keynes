#include "economy_graph_kernels.h"
#include "economy_graph_stage_dispatch.h"

namespace pk {

bool economy_kernel_building_commit(EconomySoAView &view,
                                    EconomyStageCursor &cursor,
                                    const RuntimeEconomyEpochInput &input,
                                    EconomyStageResult &result,
                                    std::string &error) {
    if (view.runtime_hook == nullptr)
        return economy_kernel_stage_boundary_stub(view, cursor, input, result,
                                                  error);
    return economy_dispatch_mutate_stage(
        view, RuntimeEconomyGraphStage::BUILDING_COMMIT, cursor, input, result,
        error);
}

} // namespace pk

#include "economy_graph_kernels.h"
#include "economy_graph_stage_dispatch.h"

namespace pk {

bool economy_kernel_research(EconomySoAView &view, EconomyStageCursor &cursor,
                             const RuntimeEconomyEpochInput &input,
                             EconomyStageResult &result, std::string &error) {
    if (view.runtime_hook == nullptr)
        return economy_kernel_stage_boundary_stub(view, cursor, input, result,
                                                  error);
    return economy_dispatch_mutate_stage(
        view, RuntimeEconomyGraphStage::GOVERNMENT_RESEARCH_PROCUREMENT, cursor,
        input, result, error);
}

} // namespace pk

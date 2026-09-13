#pragma once

// Godot-free Economy stage mutate dispatch. Named kernel TUs call this when
// EconomySoAView::runtime_hook is bound; formulas stay on NativeEconomyRuntime.

#include "economy_graph_kernels.h"

#include <string>

namespace pk {

bool economy_dispatch_mutate_stage(void *runtime_hook,
                                   RuntimeEconomyGraphStage stage,
                                   EconomyStageCursor &cursor,
                                   const RuntimeEconomyEpochInput &input,
                                   EconomyStageResult &result,
                                   std::string &error);

} // namespace pk

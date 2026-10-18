#pragma once

#include "runtime_trigger_pod.h"

#include <string>
#include <vector>

namespace pk {

class RuntimeTriggerKernel {
public:
    static bool replay_completed_research_signal(const RuntimeTriggerPodCatalog &catalog,
        RuntimeTriggerSnapshot &state, int32_t trigger_id, uint64_t target,
        int32_t cell, int64_t day, std::string &error,
        bool *enqueued = nullptr);
    static bool evaluate_day(const RuntimeTriggerPodCatalog &catalog,
                             RuntimeTriggerSnapshot &state,
                             int64_t day,
                             std::vector<RuntimeTriggerEffectIntent> &emitted,
                             std::string &error,
                             bool reference_binding_scan = false);
};

} // namespace pk

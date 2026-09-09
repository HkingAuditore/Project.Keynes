#pragma once

#include "runtime_trigger_pod.h"

#include <string>
#include <vector>

namespace pk {

class RuntimeTriggerKernel {
public:
    static bool evaluate_day(const RuntimeTriggerPodCatalog &catalog,
                             RuntimeTriggerSnapshot &state,
                             int64_t day,
                             std::vector<RuntimeTriggerEffectIntent> &emitted,
                             std::string &error);
};

} // namespace pk

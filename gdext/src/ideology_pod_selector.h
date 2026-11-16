#pragma once

#include <string>

#include "runtime_ideology_pod.h"

namespace pk {

class EffectRuntime;

namespace ideology_pod {

// Copies a program's selector columns onto a pod modifier template.
//
// The pod can only emit country-scoped rows today; the selector is what a later
// stage needs in order to expand those rows onto their real targets
// (docs/plans/ideology-worker-pod-conditions-plan.md). Nothing reads the fields
// yet, so an absent runtime or an unknown program simply leaves the defaults.
void fill_selector(EffectRuntime *runtime, const std::string &program,
                   RuntimeIdeologyPodModifierTemplate &row);

}  // namespace ideology_pod
}  // namespace pk

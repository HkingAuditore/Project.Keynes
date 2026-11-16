#include "ideology_runtime.h"

#include "economy_api.h"

namespace pk {

// See the declaration in `ideology_runtime.h`.
//
// The derived collect step creates one contribution per target cell BEFORE any effect
// instance exists, so `EffectRuntime::evaluate_condition()` (which reads an
// instance-bound metric block) cannot be used there. It samples the cell's metric row
// instead and runs the same condition stack
// (`EffectRuntime::program_conditions_hold(program_key, ...)`).
//
// Returns TRUE when the contribution may be folded, including every case this function
// cannot judge (no economy runtime, no effect runtime, unknown program): the gate is
// meant to remove magnitudes a program did not earn, never to mute a program it cannot
// evaluate.
bool NativeIdeologyRuntime::derived_target_conditions_hold(
        const std::string &program, int32_t cell) const {
    if (_effect_runtime == nullptr || _economy_runtime == nullptr) return true;
    if (program.empty() || cell < 0) return true;
    const int32_t count = static_cast<int32_t>(EconomyApi::FAMILY_METRIC_COUNT);
    std::vector<int64_t> metrics(static_cast<size_t>(count), 0);
    const MetricMask all = MetricMask::all_declared(count);
    economy_api::sample_effect_metrics(*_economy_runtime, cell, count,
                                       metrics.data(), all);
    return _effect_runtime->program_conditions_hold(program, metrics.data(), count,
                                                    0, false);
}

}  // namespace pk

#include "effect_runtime.h"

#include <array>

namespace pk {

namespace {
// Same depth as the instance evaluator (`effect_runtime.cpp:36`).
constexpr int32_t kConditionStackDepth = 256;
}  // namespace

// See the declaration in `effect_runtime.h`. Mirrors `evaluate_condition()`'s stack
// machine, with the metric read replaced by the caller's row: the derived collect step
// has no Instance yet, and `metric_ptr()` indexes an instance-bound block.
bool EffectRuntime::program_conditions_hold(int32_t program_id,
                                            const int64_t *metrics,
                                            int32_t metric_count,
                                            int64_t scope_value,
                                            bool has_scope_value) const {
    if (program_id < 0 ||
        program_id >= static_cast<int32_t>(_definitions.size()))
        return true;  // unknown program: nothing to gate
    const Definition &definition = _definitions[static_cast<size_t>(program_id)];
    if (definition.condition_count <= 0) return true;
    if (definition.condition_begin < 0) return false;
    std::array<uint8_t, kConditionStackDepth> stack{};
    int32_t sp = 0;
    const int32_t begin = definition.condition_begin;
    const int64_t end = static_cast<int64_t>(begin) + definition.condition_count;
    for (int64_t i = begin; i < end; ++i) {
        if (i < 0 || i >= static_cast<int64_t>(_conditions.size())) return false;
        const Condition &condition = _conditions[static_cast<size_t>(i)];
        const int64_t metric =
            (metrics != nullptr && condition.arg0 >= 0 &&
             condition.arg0 < metric_count)
                ? metrics[condition.arg0]
                : 0;
        bool value = false;
        switch (condition.op) {
            case CONDITION_TRUE: value = true; break;
            case METRIC_GTE: value = metric >= condition.value; break;
            case METRIC_LTE: value = metric <= condition.value; break;
            case METRIC_EQ: value = metric == condition.value; break;
            case STATE_GTE:
                value = has_scope_value && scope_value >= condition.value;
                break;
            case BOOL_AND:
                if (sp < 2) return false;
                value = stack[static_cast<size_t>(sp) - 2] != 0 &&
                        stack[static_cast<size_t>(sp) - 1] != 0;
                --sp;
                stack[static_cast<size_t>(sp) - 1] = value ? 1 : 0;
                continue;
            case BOOL_OR:
                if (sp < 2) return false;
                value = stack[static_cast<size_t>(sp) - 2] != 0 ||
                        stack[static_cast<size_t>(sp) - 1] != 0;
                --sp;
                stack[static_cast<size_t>(sp) - 1] = value ? 1 : 0;
                continue;
            case BOOL_NOT:
                if (sp < 1) return false;
                stack[static_cast<size_t>(sp) - 1] =
                    stack[static_cast<size_t>(sp) - 1] == 0 ? 1 : 0;
                continue;
            default: return false;
        }
        if (sp >= kConditionStackDepth) return false;
        stack[static_cast<size_t>(sp)] = value ? 1 : 0;
        ++sp;
    }
    return sp > 0 && stack[static_cast<size_t>(sp) - 1] != 0;
}

bool EffectRuntime::program_conditions_hold(const std::string &program_key,
                                            const int64_t *metrics,
                                            int32_t metric_count,
                                            int64_t scope_value,
                                            bool has_scope_value) const {
    if (program_key.empty()) return true;  // no program: nothing to gate
    for (int32_t index = 0; index < static_cast<int32_t>(_definitions.size());
         ++index) {
        if (_definitions[static_cast<size_t>(index)].key != program_key) continue;
        return program_conditions_hold(index, metrics, metric_count, scope_value,
                                       has_scope_value);
    }
    return true;  // unknown program: leave the caller's behaviour unchanged
}

}  // namespace pk

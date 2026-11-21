#pragma once

#include "runtime_trigger_pod.h"

#include <array>
#include <cstddef>

namespace pk {

// Both rule catalogs compile to the same boolean stack. The caller resolves
// leaves against its typed inputs; only the boolean instructions are shared.
template <size_t Capacity, class Operation, class ReadLeaf>
bool evaluate_trigger_conditions(size_t count, Operation operation, ReadLeaf read_leaf) {
    using Op = RuntimeTriggerConditionOp;
    std::array<bool, Capacity> stack{};
    size_t depth = 0;
    for (size_t index = 0; index < count; ++index) {
        const Op op = operation(index);
        if (op == Op::BOOL_NOT) {
            if (depth == 0) return false;
            stack[depth - 1] = !stack[depth - 1];
        } else if (op == Op::BOOL_AND || op == Op::BOOL_OR) {
            if (depth < 2) return false;
            const bool right = stack[--depth];
            bool &left = stack[depth - 1];
            left = op == Op::BOOL_AND ? left && right : left || right;
        } else {
            if (depth == Capacity || !read_leaf(index, stack[depth])) return false;
            ++depth;
        }
    }
    return depth == 1 && stack[0];
}

} // namespace pk

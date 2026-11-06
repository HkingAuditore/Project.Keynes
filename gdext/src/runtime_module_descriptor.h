#pragma once

#include "runtime_pod_protocol.h"
#include "runtime_external_advancers.h"
#include "runtime_module_contracts.h"

namespace pk {

// Describes the existing day stages, not permission to access another store.
// Reads/writes are reviewable inventory; the legacy handlers still enforce
// their own authority gates. No Godot types or save-format changes here.
template <typename StageFunction>
struct RuntimeModuleDescriptor {
    const char *id;
    RuntimeDomainId domain;
    StageFunction stage;
    const char *reads;
    const char *writes;
    bool main_thread_only;
    const RuntimeModuleContract *contract;
};

template <typename StageFunction, size_t N>
constexpr bool runtime_module_order_matches(
        const std::array<RuntimeModuleDescriptor<StageFunction>, N> &modules) {
    const auto order = runtime_domain_stage_order();
    if (N != order.size()) return false;
    for (size_t i = 0; i < N; ++i) {
        if (modules[i].domain != order[i] || modules[i].stage == nullptr || modules[i].contract == nullptr ||
            modules[i].contract->domain != order[i])
            return false;
    }
    return true;
}

} // namespace pk

#include "world_ext.h"
#include "native_simulation_host.h"
#include "native_parallel_executor.h"
#include "runtime_domain_pod.h"
#include "runtime_country_pod.h"
#include "country_runtime.h"
#include "economy_runtime.h"
#include "runtime_protocol_guard.h"
#include "runtime_ideology_pod.h"
#include "runtime_economy_pod.h"
#include "economy_graph_kernels.h"
#include "effect_runtime.h"
#include "ideology_runtime.h"
#include "metric_mask_tests.h"
#include "runtime_switch_registry.h"
#include "world_ext_simulation_host_internal.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>

namespace pk {

using namespace godot;

bool DCWorldExt::runtime_snapshot_ring_self_test() const {
    return RuntimeSnapshotRing::self_test();
}

bool DCWorldExt::runtime_domain_pod_self_test() const {
    std::string error;
    return RuntimeDomainPodPipeline::self_test(error);
}

bool DCWorldExt::runtime_authoritative_domains_self_test() const {
    std::string error;
    return RuntimeAuthoritativeDomainStores::self_test(error) &&
        RuntimeClimateAuthority::self_test(error) &&
        RuntimeCountryPodAuthority::self_test(error) &&
        RuntimeDomainAuthorityRunner::self_test(error);
}

bool DCWorldExt::runtime_climate_authority_self_test() const {
    std::string error;
    return RuntimeClimateAuthority::self_test(error);
}

bool DCWorldExt::runtime_climate_trace_self_test() const {
    std::string error;
    return RuntimeClimateTrace::self_test(error);
}

bool DCWorldExt::runtime_country_pod_authority_self_test() const {
    std::string error;
    const bool ok = RuntimeCountryPodAuthority::self_test(error);
    if (!ok && !error.empty())
        godot::UtilityFunctions::printerr(
            godot::String("runtime_country_pod_self_test: ") +
            godot::String(error.c_str()));
    return ok;
}

bool DCWorldExt::runtime_protocol_guard_self_test() const {
    std::string error;
    return RuntimeProtocolGuard::self_test(error);
}

bool DCWorldExt::runtime_trigger_pod_self_test() const {
    std::string error;
    return RuntimeTriggerPodAuthority::self_test(error);
}

bool DCWorldExt::runtime_effect_pod_self_test() const {
    std::string error;
    const bool ok = RuntimeEffectPodAuthority::self_test(error) &&
        (_effect_runtime == nullptr ||
         static_cast<const EffectRuntime *>(_effect_runtime)->pod_snapshot_persistence_self_test(error)) &&
        (_effect_runtime == nullptr ||
         static_cast<const EffectRuntime *>(_effect_runtime)->pod_state_parity_self_test(error));
    if (!ok) {
        godot::UtilityFunctions::printerr(
            godot::String("runtime_effect_pod_self_test: ") +
            godot::String(error.c_str()));
    }
    return ok;
}

bool DCWorldExt::runtime_effect_host_stage_self_test() {
    if (!_runtime_host) _runtime_host = std::make_unique<NativeSimulationHost>();
    std::string error;
    const bool ok = _runtime_host->effect_pod_host_stage_self_test(&error) &&
        _runtime_host->effect_pod_transport_queue_self_test(&error);
    if (!ok) {
        godot::UtilityFunctions::printerr(
            godot::String("runtime_effect_host_stage_self_test: ") +
            godot::String(error.c_str()));
    }
    return ok;
}

bool DCWorldExt::runtime_effect_adapter_parity_self_test() {
    if (!_runtime_host) _runtime_host = std::make_unique<NativeSimulationHost>();
    std::string error;
    const bool ok = _runtime_host->modifier_effect_adapter_self_test(&error);
    if (!ok) {
        godot::UtilityFunctions::printerr(
            godot::String("runtime_effect_adapter_parity_self_test: ") +
            godot::String(error.c_str()));
    }
    return ok;
}

bool DCWorldExt::runtime_ideology_pod_self_test() const {
    std::string error;
    const bool ok = RuntimeIdeologyPodAuthority::self_test(error);
    if (!ok) {
        godot::UtilityFunctions::printerr(
            godot::String("runtime_ideology_pod_self_test: ") +
            godot::String(error.c_str()));
    }
    return ok;
}

bool DCWorldExt::runtime_events_authority_self_test() const {
    std::string error;
    const bool ok = RuntimeEventsAuthority::self_test(error) &&
        RuntimeEventsSnapshotRing::self_test();
    if (!ok) {
        godot::UtilityFunctions::printerr(
            godot::String("runtime_events_authority_self_test: ") +
            godot::String(error.c_str()));
    }
    return ok;
}

bool DCWorldExt::runtime_economy_pod_self_test() const {
    std::string error;
    const bool ok = RuntimeEconomyPodAuthority::self_test(error);
    if (!ok) {
        godot::UtilityFunctions::printerr(
            godot::String("runtime_economy_pod_self_test: ") +
            godot::String(error.c_str()));
    }
    return ok;
}

bool DCWorldExt::runtime_economy_authority_fault_gate_self_test() const {
    auto probe = std::make_unique<NativeSimulationHost>();
    std::string error;
    const bool ok = probe->economy_authority_fault_gate_self_test(error);
    if (!ok) {
        godot::UtilityFunctions::printerr(
            godot::String("runtime_economy_authority_fault_gate_self_test: ") +
            godot::String(error.c_str()));
    }
    return ok;
}

bool DCWorldExt::runtime_economy_target_selector_self_test() const {
    std::string error;
    const bool ok = EconomyTargetSelectorTests::run(error);
    if (!ok) {
        godot::UtilityFunctions::printerr(
            godot::String("runtime_economy_target_selector_self_test: ") +
            godot::String(error.c_str()));
    }
    return ok;
}

bool DCWorldExt::runtime_metric_mask_self_test() const {
    std::string error;
    const bool ok = MetricMaskTests::run(error);
    if (!ok) {
        godot::UtilityFunctions::printerr(
            godot::String("runtime_metric_mask_self_test: ") +
            godot::String(error.c_str()));
    }
    return ok;
}

bool DCWorldExt::arm_runtime_fault_injection(const godot::String &point) {
    if (!_runtime_host) return false;
    const CharString utf8 = point.utf8();
    return _runtime_host->arm_fault_injection(utf8.get_data());
}

void DCWorldExt::clear_runtime_fault_injection() {
    if (!_runtime_host) return;
    _runtime_host->clear_fault_injection();
}

godot::Dictionary DCWorldExt::runtime_economy_stage_order_contract_test() const {
    godot::Dictionary out;
    std::string error;
    const bool ok = economy_graph_kernels_self_test(error);
    out["ok"] = ok;
    out["stage_count"] = static_cast<int64_t>(RUNTIME_ECONOMY_GRAPH_STAGE_COUNT);
    out["all_stage_mask"] = static_cast<int64_t>(RUNTIME_ECONOMY_GRAPH_ALL_STAGE_MASK);
    godot::PackedStringArray names;
    names.resize(static_cast<int64_t>(RUNTIME_ECONOMY_GRAPH_STAGE_COUNT));
    for (size_t i = 0; i < RUNTIME_ECONOMY_GRAPH_STAGE_COUNT; ++i) {
        names.set(static_cast<int64_t>(i), godot::String(
            runtime_economy_graph_stage_name(
                static_cast<RuntimeEconomyGraphStage>(i))));
    }
    out["stage_names"] = names;
    if (!ok) out["error"] = godot::String(error.c_str());
    return out;
}

bool DCWorldExt::runtime_climate_writeback_self_test() const {
    std::string error;
    return RuntimeClimateWritebackRing::self_test(error) &&
           RuntimeEnvironmentInputRing::self_test(error);
}

Dictionary DCWorldExt::runtime_climate_parity_contract_test() const {
    Dictionary out;
    std::string error;
    const bool ok = runtime_climate_parity_self_test(error);
    out["ok"] = ok;
    // 返回 Dictionary 而不是裸 bool：一次 parity 契约失败必须带上原因才可行动，
    // 而"绿灯下的裸 false"正是早期几个缺口能长期隐身的原因。
    out["code"] = ok ? String("ok") : String(error.c_str());
    out["parity_version"] =
        static_cast<int64_t>(RUNTIME_CLIMATE_PARITY_VERSION);
    out["fields_total"] =
        static_cast<int64_t>(runtime_climate_parity_field_count());
    out["fields_comparable"] =
        static_cast<int64_t>(runtime_climate_parity_comparable_count());
    out["fields_max"] =
        static_cast<int64_t>(RUNTIME_CLIMATE_PARITY_MAX_FIELDS);
    return out;
}

} // namespace pk

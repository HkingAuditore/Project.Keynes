#include "economy_cost_probe.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
#include "native_simulation_host.h"
#include "economy_runtime_variant_helpers.h"
#include "parallel_dispatcher.h"
#include "pk_log.h"

#include <algorithm>
#include <array>
#include <cassert>
#include <chrono>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iterator>
#include <limits>
#include <map>
#include <numeric>
#include <tuple>
#include <type_traits>
#include <unordered_map>
#include <unordered_set>

#if defined(_MSC_VER) && defined(_M_X64)
#include <intrin.h>
#endif

#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <godot_cpp/variant/variant.hpp>

namespace pk {
using namespace godot;
using namespace variant_helpers;

class NativeEconomyBuildingPlanExecutor final : public EconomyBuildingPlanExecutor {
public:
    NativeEconomyRuntime *runtime = nullptr;
    NativeEconomyRuntime::BuildingPlanResult *legacy_result = nullptr;

    bool execute(int32_t active_begin, int32_t active_end,
                 const int32_t *cells_override, int32_t cells_count,
                 EconomyBuildingPlanResult &result,
                 std::string &error) override;
};

bool NativeEconomyBuildingPlanExecutor::execute(
        int32_t active_begin, int32_t active_end,
        const int32_t *cells_override, int32_t cells_count,
        EconomyBuildingPlanResult &result, std::string &error) {
    if (runtime == nullptr || legacy_result == nullptr) {
        error = "economy_building_plan_executor_unbound";
        result.ok = false;
        return false;
    }
    std::vector<int32_t> override_storage;
    const std::vector<int32_t> *override_ptr = nullptr;
    if (cells_override != nullptr && cells_count > 0) {
        override_storage.assign(cells_override, cells_override + cells_count);
        override_ptr = &override_storage;
    }
    if (!runtime->prepare_building_economic_plan_body(
            active_begin, active_end, override_ptr, *legacy_result, error)) {
        result.ok = false;
        if (!error.empty()) {
            const size_t n = error.size() < sizeof(result.error) - 1u
                ? error.size() : sizeof(result.error) - 1u;
            std::memcpy(result.error, error.data(), n);
            result.error[n] = '\0';
        }
        return false;
    }
    result.ok = legacy_result->ok;
    result.saturation_count = legacy_result->saturation_count;
    result.merchant_credit_budget = legacy_result->merchant_credit_budget;
    result.merchant_credit_committed = legacy_result->merchant_credit_committed;
    result.recovery_candidates = legacy_result->recovery_candidates;
    result.recovery_approved = legacy_result->recovery_approved;
    result.loss_suspended_building_groups =
        legacy_result->loss_suspended_building_groups;
    result.unprofitable_building_groups =
        legacy_result->unprofitable_building_groups;
    result.utilization_sum_q16 = legacy_result->utilization_sum_q16;
    result.worker_ms = legacy_result->worker_ms;
    return legacy_result->ok;
}

bool NativeEconomyRuntime::prepare_building_economic_plan(
        int32_t active_begin, int32_t active_end,
        const std::vector<int32_t> *cells_override,
        BuildingPlanResult &result, std::string &error) {
    LivingCostMemoScope memo(*this, true);
    result.reset();
    NativeEconomyBuildingPlanExecutor executor;
    executor.runtime = this;
    executor.legacy_result = &result;
    EconomyBuildingPlanResult kernel_result;
    const int32_t *override_data =
        cells_override != nullptr ? cells_override->data() : nullptr;
    const int32_t override_count = cells_override != nullptr
        ? static_cast<int32_t>(cells_override->size()) : 0;
    return economy_kernel_prepare_building_plan(
        executor, active_begin, active_end, override_data, override_count,
        kernel_result, error);
}

} // namespace pk

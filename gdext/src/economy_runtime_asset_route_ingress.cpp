#include "economy_cost_probe.h"
#include "economy_effect_forward.h"
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

NativeEconomyRuntime::CountryWorkerAssetRoute
NativeEconomyRuntime::block_or_enqueue_country_worker_asset(
        uint16_t operation, int64_t country_handle, int64_t cash,
        int64_t quantity, int32_t good_id, std::string &error,
        uint64_t *request_id) {
    std::vector<int32_t> ids;
    std::vector<int64_t> quantities;
    if (good_id >= 0) {
        ids.push_back(good_id);
        quantities.push_back(quantity);
    }
    return block_or_enqueue_country_worker_asset(
        operation, country_handle, cash, quantity, ids, quantities, error,
        request_id);
}

} // namespace pk

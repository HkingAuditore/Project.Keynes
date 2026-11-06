#include "economy_cost_probe.h"
#include "economy_runtime.h"
#include "economy_hash.h"
#include "runtime_switch_registry.h"
#include "economy_graph_kernels.h"
#include "economy_graph_live_ops.h"
#include "economy_graph_stage_dispatch.h"
#include "runtime_economy_pod.h"
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

bool NativeEconomyRuntime::valid_family_effect_entity_handle(
        uint64_t handle) const {
    int32_t index = -1;
    return families_store().valid_handle(handle, index) ||
        family_influences().valid_handle(handle, index);
}

bool NativeEconomyRuntime::valid_family_effect_target_handle(
        uint64_t handle) const {
    int32_t index = -1;
    return families_store().valid_handle(handle, index);
}

void NativeEconomyRuntime::collect_family_effect_target_handles(
        int32_t country_slot, int32_t min_branches, int32_t cap,
        std::vector<uint64_t> &out_handles) const {
    out_handles.clear();
    if (country_slot < 0 || min_branches < 1 || cap < 1) return;
    const auto &families = families_store();
    const auto &influences = family_influences();
    std::vector<int32_t> branch_counts(families.active.size(), 0);
    for (int32_t branch = 0; branch < static_cast<int32_t>(
            influences.active.size()); ++branch) {
        if (influences.active[branch] == 0) continue;
        int32_t family = -1;
        if (!families.valid_handle(influences.family_handle[branch], family) ||
            family < 0 || family >= static_cast<int32_t>(
                branch_counts.size()))
            continue;
        if (cell_country_slot(influences.cell[branch]) != country_slot)
            continue;
        ++branch_counts[static_cast<size_t>(family)];
    }
    for (int32_t family = 0; family < static_cast<int32_t>(
            families.active.size()); ++family) {
        if (families.active[family] == 0 ||
            branch_counts[static_cast<size_t>(family)] < min_branches)
            continue;
        const uint64_t handle = families.handle_for_index(family);
        if (family_owned_buildings(handle) <= 0)
            continue;
        out_handles.push_back(handle);
        if (static_cast<int32_t>(out_handles.size()) >= cap) break;
    }
}

void NativeEconomyRuntime::set_family_target_min_branches_override_for_test(
        int32_t min_branches) {
    _family_target_min_branches_override_for_test = std::max(0, min_branches);
}

bool NativeEconomyRuntime::cell_has_requirements(
        int32_t cell, int32_t begin, int32_t end,
        const std::vector<int32_t> &requirements, bool frozen) const {
    if (begin < 0 || end < begin || end > static_cast<int32_t>(requirements.size())) return false;
    if (begin == end) return true;
    for (int32_t i = begin; i < end; ++i) {
        if (cell_has_technology(cell, requirements[i], frozen)) return true;
    }
    return false;
}

bool NativeEconomyRuntime::cell_has_all_requirements(
        int32_t cell, int32_t begin, int32_t end,
        const std::vector<int32_t> &requirements, bool frozen) const {
    if (begin < 0 || end < begin || end > static_cast<int32_t>(requirements.size())) return false;
    for (int32_t i = begin; i < end; ++i) {
        if (!cell_has_technology(cell, requirements[i], frozen)) return false;
    }
    return true;
}

bool NativeEconomyRuntime::good_production_available(
        int32_t cell, int32_t good_id, bool frozen) const {
    if (frozen && _epoch_active && cell >= 0 && cell < _cell_count.get() &&
        good_id >= 0 && good_id < static_cast<int32_t>(_good_ids.size()) &&
        _epoch_cell_country.size() == static_cast<size_t>(_cell_count.get())) {
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        const size_t index = static_cast<size_t>(std::max(0, country)) *
            _good_ids.size() + static_cast<size_t>(good_id);
        if (country >= 0 && country < _epoch_country_count &&
            index < _epoch_country_good_available.size() &&
            _epoch_country_good_available[index] != 0)
            return true;
        // A country capability snapshot can legitimately lag a catalog or
        // fixture mutation by one epoch. Preserve the snapshot's positive
        // authority, but do not turn a locally valid, already unlocked good
        // into a permanent false solely because its frozen bit is stale.
    }
    return good_id >= 0 && good_id + 1 < static_cast<int32_t>(_good_technology_offsets.size()) &&
        cell_has_requirements(cell, _good_technology_offsets[good_id],
            _good_technology_offsets[good_id + 1], _good_required_technologies, frozen);
}

bool NativeEconomyRuntime::good_market_available(
        int32_t cell, int32_t good_id, bool frozen) const {
    if (frozen && _epoch_active && cell >= 0 && cell < _cell_count.get() &&
        good_id >= 0 && good_id < static_cast<int32_t>(_good_ids.size()) &&
        _epoch_cell_country.size() == static_cast<size_t>(_cell_count.get())) {
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        if (country < 0 || country >= _epoch_country_count) return false;
        const size_t index = static_cast<size_t>(country) * _good_ids.size() +
            static_cast<size_t>(good_id);
        // The frozen country market table is a permission snapshot, but it
        // must not hide a locally producible/input good. During bootstrap and
        // catalog-mutating fixtures the market lane can lag the production
        // capability by one epoch; retain the capability fallback below.
        if (index < _epoch_country_market_available.size() &&
            _epoch_country_market_available[index] != 0)
            return true;
    }
    if (good_production_available(cell, good_id, frozen)) return true;
    return good_id >= 0 && good_id < static_cast<int32_t>(_good_ids.size()) &&
        good_id < static_cast<int32_t>(_good_trade_enabled.size()) &&
        good_id < static_cast<int32_t>(_good_storage_modes.size()) &&
        _good_trade_enabled[good_id] != 0 && _good_storage_modes[good_id] == 0;
}

bool NativeEconomyRuntime::good_input_candidate_available(
        int32_t cell, int32_t good_id, bool frozen) const {
    if (cell < 0 || cell >= _cell_count.get() || good_id < 0 ||
        good_id >= static_cast<int32_t>(_good_ids.size())) return false;
    const int32_t market = market_store().cell_to_market[cell];
    if (market < 0 || market >= market_store().market_count.get()) return false;
    const int64_t stock = std::max<int64_t>(0,
        market_store().stock[market_store().index(market, good_id)]);
    if (stock > 0) return true;
    const int32_t signal = market_signal_index(cell, good_id);
    const int64_t offered = signal >= 0 &&
            signal < static_cast<int32_t>(_market_signals.offered_supply_ema.size())
        ? std::max<int64_t>(0, _market_signals.offered_supply_ema[signal]) : 0;
    if (offered > 0) return good_market_available(cell, good_id, frozen);
    // Empty shelf, no offer: only tech-unlocked producers. Otherwise stone-age
    // soft tools demand books onto metal `tools` solely because trade_enabled
    // makes every stock good "market available".
    return good_production_available(cell, good_id, frozen);
}

bool NativeEconomyRuntime::good_available(
        int32_t cell, int32_t good_id, bool frozen) const {
    return good_production_available(cell, good_id, frozen);
}

bool NativeEconomyRuntime::profession_available(int32_t cell, int32_t profession_id,
                                                bool frozen) const {
    if (frozen && _epoch_active && cell >= 0 && cell < _cell_count.get() &&
        profession_id >= 0 &&
        profession_id < static_cast<int32_t>(_profession_ids.size()) &&
        _epoch_cell_country.size() == static_cast<size_t>(_cell_count.get())) {
        const int32_t country = _epoch_cell_country[static_cast<size_t>(cell)];
        const size_t index = static_cast<size_t>(std::max(0, country)) *
            _profession_ids.size() + static_cast<size_t>(profession_id);
        return country >= 0 && country < _epoch_country_count &&
            index < _epoch_country_profession_available.size() &&
            _epoch_country_profession_available[index] != 0;
    }
    return profession_id >= 0 &&
        profession_id + 1 < static_cast<int32_t>(_profession_technology_offsets.size()) &&
        cell_has_requirements(cell, _profession_technology_offsets[profession_id],
            _profession_technology_offsets[profession_id + 1],
            _profession_required_technologies, frozen);
}

} // namespace pk
